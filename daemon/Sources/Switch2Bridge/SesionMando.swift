@preconcurrency import CoreBluetooth
import Foundation
import OSLog

/// Sesión BLE con un mando de Switch 2.
///
/// Descubre el mando por los datos de fabricante del anuncio, se conecta,
/// ejecuta el saludo del protocolo (identificación, calibración, LEDs y
/// activación de funciones) y difunde el estado normalizado.
final class SesionMando: NSObject, @unchecked Sendable {
    private let registro = Registro(categoria: "mando")
    private let servidor: ServidorEstado
    private let cola = DispatchQueue(label: "dev.swondev.switch2bridge.ble")

    private var central: CBCentralManager!
    private var periferico: CBPeripheral?
    private var modelo: Protocolo.Modelo?

    private var caracEntrada: CBCharacteristic?
    private var caracEscrituraComando: CBCharacteristic?
    private var caracRespuestaComando: CBCharacteristic?

    private var calibracionIzquierda = CalibracionStick.porDefecto
    private var calibracionDerecha = CalibracionStick.porDefecto

    /// Continuación pendiente a la espera de la respuesta a un comando.
    private var esperaRespuesta: CheckedContinuation<Data, Error>?
    private var comandoEnCurso: UInt8?
    private var secuenciaComando: UInt64 = 0

    /// Identificador del último mando conocido, para reconectar sin escanear.
    private let claveUltimoMando = "ultimoMandoUUID"

    private var saludoIniciado = false

    /// Instante del último reporte recibido, para detectar silencio.
    private var ultimoReporte = Date.distantPast
    private var latido: DispatchSourceTimer?

    init(servidor: ServidorEstado) {
        self.servidor = servidor
        super.init()
        central = CBCentralManager(delegate: self, queue: cola)
        arrancarLatido()
    }

    /// Emite un estado "desconectado" mientras no lleguen reportes.
    ///
    /// Sin esto, las herramientas de diagnóstico se quedarían bloqueadas
    /// esperando una trama que nunca llega cuando el mando está dormido.
    private func arrancarLatido() {
        let temporizador = DispatchSource.makeTimerSource(queue: cola)
        temporizador.schedule(deadline: .now() + 1, repeating: 1)
        temporizador.setEventHandler { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.ultimoReporte) > 1.0 else { return }
            var estado = EstadoMando()
            estado.conectado = false
            self.servidor.difundir(estado)
        }
        temporizador.resume()
        latido = temporizador
    }

    // MARK: - Descubrimiento

    private func empezarBusqueda() {
        guard central.state == .poweredOn else { return }

        // Pide la reconexión al mando ya conocido: si vuelve a estar cerca es
        // instantánea y no requiere pulsar SYNC.
        if let texto = UserDefaults.standard.string(forKey: claveUltimoMando),
           let uuid = UUID(uuidString: texto),
           let conocido = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            registro.info("solicitando reconexión al mando conocido")
            periferico = conocido
            conocido.delegate = self
            central.connect(conocido, options: nil)
        }

        // …y escanea en paralelo. `connect` no caduca nunca, así que confiar
        // sólo en él dejaría el puente ciego ante un mando distinto o reiniciado.
        guard !central.isScanning else { return }
        registro.info("buscando mandos de Switch 2…")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Extrae fabricante y modelo de los datos de fabricante del anuncio.
    private func identificar(_ anuncio: [String: Any]) -> Protocolo.Modelo? {
        guard let datos = anuncio[CBAdvertisementDataManufacturerDataKey] as? Data,
              datos.count >= 13 else { return nil }
        // Los dos primeros bytes son el identificador de compañía.
        let compania = Protocolo.leerU16(datos, 0)
        guard compania == Protocolo.companyIDNintendo else { return nil }
        let cuerpo = datos.dropFirst(2)
        let fabricante = Protocolo.leerU16(Data(cuerpo), 3)
        let producto = Protocolo.leerU16(Data(cuerpo), 5)
        guard fabricante == Protocolo.fabricanteNintendo else { return nil }
        return Protocolo.Modelo(rawValue: producto)
    }

    // MARK: - Comandos

    /// Envía un comando y espera su respuesta.
    ///
    /// Todo el trabajo ocurre en la cola serie de CoreBluetooth, así que los
    /// objetos de CoreBluetooth (que no son `Sendable`) nunca cruzan hilos.
    /// El temporizador de seguridad se identifica por número de secuencia para
    /// que el vencimiento de un comando antiguo no cancele al siguiente.
    private func enviarComando(_ comando: UInt8, _ subcomando: UInt8,
                               datos: Data = Data(), tiempoLimite: TimeInterval = 2.0) async throws -> Data {
        let trama = Protocolo.construirComando(comando, subcomando, datos: datos)

        return try await withCheckedThrowingContinuation { continuacion in
            cola.async { [weak self] in
                guard let self else {
                    continuacion.resume(throwing: ErrorPuente.bluetooth("sesión finalizada"))
                    return
                }
                guard let caracEscritura = self.caracEscrituraComando, let periferico = self.periferico else {
                    continuacion.resume(throwing: ErrorPuente.bluetooth("mando no listo para recibir comandos"))
                    return
                }

                self.secuenciaComando &+= 1
                let secuencia = self.secuenciaComando
                self.comandoEnCurso = comando
                self.esperaRespuesta = continuacion

                periferico.writeValue(trama, for: caracEscritura, type: .withoutResponse)

                self.cola.asyncAfter(deadline: .now() + tiempoLimite) { [weak self] in
                    guard let self, self.secuenciaComando == secuencia,
                          let pendiente = self.esperaRespuesta else { return }
                    self.esperaRespuesta = nil
                    pendiente.resume(throwing: ErrorPuente.tiempoAgotado("comando \(comando)/\(subcomando)"))
                }
            }
        }
    }

    /// Lee un bloque de la memoria interna del mando (máximo 0x4F bytes).
    private func leerMemoria(longitud: UInt8, direccion: UInt32) async throws -> Data {
        let carga = Protocolo.cargaLecturaMemoria(longitud: longitud, direccion: direccion)
        let respuesta = try await enviarComando(Protocolo.comandoMemoria, Protocolo.subcomandoLeerMemoria, datos: carga)
        guard respuesta.count > 8, respuesta[respuesta.startIndex] == longitud else {
            throw ErrorPuente.bluetooth("respuesta de lectura inesperada")
        }
        return Data(respuesta.dropFirst(8))
    }

    private func leerCalibracionStick(usuario: UInt32, fabrica: UInt32) async -> CalibracionStick {
        do {
            var datos = try await leerMemoria(longitud: 0x0B, direccion: usuario)
            // 0xFFFFFF significa "sin calibración de usuario": usa la de fábrica.
            if datos.count >= 3, datos[datos.startIndex] == 0xFF, datos[datos.startIndex + 1] == 0xFF,
               datos[datos.startIndex + 2] == 0xFF {
                datos = try await leerMemoria(longitud: 0x0B, direccion: fabrica)
            }
            return CalibracionStick(datos: datos) ?? .porDefecto
        } catch {
            registro.aviso("no se pudo leer la calibración (\(String(describing: error))); usando la neutra")
            return .porDefecto
        }
    }

    /// Saludo completo tras conectar: identifica, calibra, enciende LED y activa la entrada.
    private func ejecutarSaludo() async {
        do {
            let info = try await leerMemoria(longitud: 0x40, direccion: Protocolo.direccionInfoMando)
            let serie = String(data: Data(info.prefix(16).dropFirst(2)), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? "?"
            registro.info("mando identificado, nº de serie \(serie)")

            calibracionIzquierda = await leerCalibracionStick(usuario: Protocolo.calibracionUsuarioStick1,
                                                              fabrica: Protocolo.calibracionStick1)
            calibracionDerecha = await leerCalibracionStick(usuario: Protocolo.calibracionUsuarioStick2,
                                                            fabrica: Protocolo.calibracionStick2)

            // LED del jugador 1.
            var cargaLED = Data([Protocolo.patronLED[1] ?? 0x01])
            cargaLED.append(contentsOf: [0, 0, 0])
            _ = try? await enviarComando(Protocolo.comandoLEDs, Protocolo.subcomandoLEDsJugador, datos: cargaLED)

            // Activa entrada básica + movimiento.
            var cargaFuncion = Data([0x03 | Protocolo.funcionMovimiento])
            cargaFuncion.append(contentsOf: [0, 0, 0])
            _ = try? await enviarComando(Protocolo.comandoFuncion, Protocolo.subcomandoFuncionInit, datos: cargaFuncion)
            _ = try? await enviarComando(Protocolo.comandoFuncion, Protocolo.subcomandoFuncionActivar, datos: cargaFuncion)

            // Por último, suscribe las notificaciones de entrada.
            if let periferico, let caracEntrada {
                periferico.setNotifyValue(true, for: caracEntrada)
            }
            saludoIniciado = true
            registro.info("mando listo: emitiendo estado")
        } catch {
            registro.error("el saludo falló: \(String(describing: error))")
        }
    }

    // MARK: - Diagnóstico

    private var ultimoVolcado: [UInt8] = []
    private var lineasVolcadas = 0

    /// Vuelca a fichero los bytes crudos cuando cambia la máscara de botones.
    ///
    /// Deliberadamente ignora los sticks: su ruido de reposo cambia en cada
    /// reporte y llenaría el registro sin aportar nada. Así cada línea equivale
    /// a una pulsación real y sirve para verificar la decodificación.
    private func volcarSiCambia(_ datos: Data) {
        guard lineasVolcadas < 400 else { return }
        let interes = Array(datos.dropFirst(4).prefix(4))  // sólo botones
        guard interes != ultimoVolcado else { return }
        ultimoVolcado = interes

        let hex = datos.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
        let ruta = (RutasPuente.soporte as NSString).appendingPathComponent("reportes.log")
        let linea = "\(Date().formatted(.dateTime.hour().minute().second()))  \(hex)\n"
        if let manejador = FileHandle(forWritingAtPath: ruta) {
            manejador.seekToEndOfFile()
            manejador.write(Data(linea.utf8))
            try? manejador.close()
        } else {
            try? linea.write(toFile: ruta, atomically: true, encoding: .utf8)
        }
        lineasVolcadas += 1
    }

    // MARK: - Normalización

    private func publicar(_ reporte: ReporteEntrada) {
        ultimoReporte = Date()
        let izquierdo = calibracionIzquierda.aplicar(reporte.stickIzquierdoBruto)
        let derecho = calibracionDerecha.aplicar(reporte.stickDerechoBruto)

        func aEje(_ valor: Double) -> Int16 {
            Int16(max(-32767, min(32767, (valor * 32767).rounded())))
        }

        var estado = EstadoMando()
        estado.botones = reporte.botones.rawValue
        estado.ejeIzquierdoX = aEje(izquierdo.x)
        // El mando da Y positivo hacia arriba; SDL lo espera hacia abajo.
        estado.ejeIzquierdoY = aEje(-izquierdo.y)
        estado.ejeDerechoX = aEje(derecho.x)
        estado.ejeDerechoY = aEje(-derecho.y)

        if modelo?.tieneGatillosAnalogicos == true {
            estado.gatilloIzquierdo = reporte.gatilloIzquierdoBruto
            estado.gatilloDerecho = reporte.gatilloDerechoBruto
        } else {
            // ZL/ZR son digitales en el Pro Controller 2.
            estado.gatilloIzquierdo = reporte.botones.contains(.zl) ? 255 : 0
            estado.gatilloDerecho = reporte.botones.contains(.zr) ? 255 : 0
        }
        estado.conectado = true
        servidor.difundir(estado)
    }

    private func publicarDesconexion() {
        var estado = EstadoMando()
        estado.conectado = false
        servidor.difundir(estado)
    }
}

// MARK: - CBCentralManagerDelegate

extension SesionMando: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let autorizacion: String
        switch CBManager.authorization {
        case .allowedAlways: autorizacion = "concedido"
        case .denied: autorizacion = "denegado"
        case .restricted: autorizacion = "restringido"
        case .notDetermined: autorizacion = "sin determinar"
        @unknown default: autorizacion = "desconocido"
        }

        switch central.state {
        case .poweredOn:
            registro.info("Bluetooth disponible (permiso: \(autorizacion))")
            empezarBusqueda()
        case .unauthorized:
            registro.error("permiso de Bluetooth \(autorizacion): concédelo en Ajustes › Privacidad y seguridad › Bluetooth")
        case .poweredOff:
            registro.aviso("Bluetooth apagado")
            publicarDesconexion()
        case .unsupported:
            registro.error("este equipo no soporta Bluetooth LE")
        case .resetting:
            registro.aviso("el subsistema Bluetooth se está reiniciando")
        case .unknown:
            registro.aviso("estado de Bluetooth aún desconocido (permiso: \(autorizacion))")
        @unknown default:
            registro.aviso("estado de Bluetooth no reconocido")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let modeloDetectado = identificar(advertisementData) else { return }
        registro.info("encontrado \(modeloDetectado.nombre) (RSSI \(RSSI))")
        modelo = modeloDetectado
        central.stopScan()
        periferico = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        registro.info("conectado; descubriendo servicios")
        central.stopScan()  // ya no hace falta gastar radio
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: claveUltimoMando)
        saludoIniciado = false
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        registro.error("fallo al conectar: \(error?.localizedDescription ?? "desconocido")")
        empezarBusqueda()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        registro.info("mando desconectado; esperando a que vuelva")
        publicarDesconexion()
        caracEntrada = nil
        caracEscrituraComando = nil
        caracRespuestaComando = nil
        saludoIniciado = false

        // Doble red: una conexión pendiente (se dispara en cuanto el mando
        // despierte) y el escaneo (por si vuelve con otra identidad tras un
        // reinicio o tras haber estado emparejado con la consola).
        central.connect(peripheral, options: nil)
        if !central.isScanning {
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }
}

// MARK: - CBPeripheralDelegate

extension SesionMando: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for servicio in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: servicio)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Volcado completo de la tabla GATT: nos dice si el mando expone algún
        // servicio HID estándar (0x1812) que macOS pudiera adoptar por sí solo.
        let ruta = (RutasPuente.soporte as NSString).appendingPathComponent("gatt.log")
        var texto = "SERVICIO \(service.uuid.uuidString)\n"
        for c in service.characteristics ?? [] {
            var props: [String] = []
            if c.properties.contains(.read) { props.append("read") }
            if c.properties.contains(.write) { props.append("write") }
            if c.properties.contains(.writeWithoutResponse) { props.append("writeSinResp") }
            if c.properties.contains(.notify) { props.append("notify") }
            texto += "   · \(c.uuid.uuidString)  [\(props.joined(separator: ","))]\n"
        }
        if let manejador = FileHandle(forWritingAtPath: ruta) {
            manejador.seekToEndOfFile()
            manejador.write(Data(texto.utf8))
            try? manejador.close()
        } else {
            try? texto.write(toFile: ruta, atomically: true, encoding: .utf8)
        }

        for carac in service.characteristics ?? [] {
            switch carac.uuid.uuidString.uppercased() {
            case Protocolo.uuidReporteEntrada:
                caracEntrada = carac
            case Protocolo.uuidEscrituraComando:
                caracEscrituraComando = carac
            case Protocolo.uuidRespuestaComando:
                caracRespuestaComando = carac
                // Hay que escuchar las respuestas antes de enviar ningún comando.
                peripheral.setNotifyValue(true, for: carac)
            default:
                break
            }
        }
        // Cuando ya tenemos las tres características, arranca el saludo.
        if caracEntrada != nil, caracEscrituraComando != nil, caracRespuestaComando != nil, !saludoIniciado {
            saludoIniciado = true  // evita relanzarlo si llegan más servicios
            Task { await self.ejecutarSaludo() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let datos = characteristic.value else { return }

        if characteristic.uuid.uuidString.uppercased() == Protocolo.uuidRespuestaComando {
            // Valida la cabecera y entrega la respuesta a quien la espera.
            guard let continuacion = esperaRespuesta else { return }
            esperaRespuesta = nil
            guard datos.count >= 8, datos[datos.startIndex + 1] == 0x01,
                  comandoEnCurso == nil || datos[datos.startIndex] == comandoEnCurso else {
                continuacion.resume(throwing: ErrorPuente.bluetooth("respuesta inesperada"))
                return
            }
            continuacion.resume(returning: Data(datos.dropFirst(8)))
            return
        }

        if characteristic.uuid.uuidString.uppercased() == Protocolo.uuidReporteEntrada,
           let reporte = ReporteEntrada(datos) {
            volcarSiCambia(datos)
            publicar(reporte)
        }
    }
}
