import Foundation

/// Protocolo BLE propietario de los mandos de Nintendo Switch 2.
///
/// Conocimiento destilado del trabajo de ingeniería inversa de la comunidad
/// (Nadeflore, ndeadly, bitaxislabs y el puente de Linux `switch2-controllers-linux`).
/// Este fichero no depende de CoreBluetooth: es sólo datos y decodificación.
enum Protocolo {
    // MARK: - Identificación

    static let fabricanteNintendo: UInt16 = 0x057E
    /// Identificador de compañía usado en los datos de fabricante del anuncio BLE.
    static let companyIDNintendo: UInt16 = 0x0553

    enum Modelo: UInt16 {
        case joyCon2Derecho = 0x2066
        case joyCon2Izquierdo = 0x2067
        case proController2 = 0x2069
        case mandoGameCubeNSO = 0x2073

        var nombre: String {
            switch self {
            case .joyCon2Derecho: return "Joy-Con 2 (derecho)"
            case .joyCon2Izquierdo: return "Joy-Con 2 (izquierdo)"
            case .proController2: return "Pro Controller 2"
            case .mandoGameCubeNSO: return "Mando GameCube NSO"
            }
        }

        /// Sólo el mando de GameCube expone gatillos analógicos reales.
        var tieneGatillosAnalogicos: Bool { self == .mandoGameCubeNSO }

        /// Actuadores de vibración HD reales (el de GameCube no tiene).
        var tieneVibracionHD: Bool { self != .mandoGameCubeNSO }
    }

    // MARK: - Características GATT

    static let uuidReporteEntrada = "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2"
    static let uuidEscrituraComando = "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005"
    static let uuidRespuestaComando = "C765A961-D9D8-4D36-A20A-5315B111836A"

    static let uuidVibracionPro = "CC483F51-9258-427D-A939-630C31F72B05"
    static let uuidVibracionJoyConDerecho = "FA19B0FB-CD1F-46A7-84A1-BBB09E00C149"
    static let uuidVibracionJoyConIzquierdo = "289326CB-A471-485D-A8F4-240C14F18241"

    static func uuidVibracion(para modelo: Modelo) -> String {
        switch modelo {
        case .joyCon2Izquierdo: return uuidVibracionJoyConIzquierdo
        case .joyCon2Derecho: return uuidVibracionJoyConDerecho
        default: return uuidVibracionPro
        }
    }

    // MARK: - Comandos

    static let comandoLEDs: UInt8 = 0x09
    static let subcomandoLEDsJugador: UInt8 = 0x07

    static let comandoVibracion: UInt8 = 0x0A
    static let subcomandoVibracionPreset: UInt8 = 0x02

    static let comandoMemoria: UInt8 = 0x02
    static let subcomandoLeerMemoria: UInt8 = 0x04

    static let comandoFuncion: UInt8 = 0x0C
    static let subcomandoFuncionInit: UInt8 = 0x02
    static let subcomandoFuncionActivar: UInt8 = 0x04

    static let funcionMovimiento: UInt8 = 0x04

    /// Patrón de LEDs de jugador, idéntico al de la consola.
    static let patronLED: [Int: UInt8] = [1: 0x01, 2: 0x03, 3: 0x07, 4: 0x0F,
                                          5: 0x09, 6: 0x05, 7: 0x0D, 8: 0x06]

    // MARK: - Direcciones de memoria del mando

    static let direccionInfoMando: UInt32 = 0x0001_3000
    static let calibracionStick1: UInt32 = 0x0001_30A8
    static let calibracionStick2: UInt32 = 0x0001_30E8
    static let calibracionUsuarioStick1: UInt32 = 0x001F_C042
    static let calibracionUsuarioStick2: UInt32 = 0x001F_C062

    // MARK: - Máscara de botones (32 bits LE, bytes 4..8 del reporte)

    struct Boton: OptionSet, Sendable {
        let rawValue: UInt32
        static let y = Boton(rawValue: 0x0000_0001)
        static let x = Boton(rawValue: 0x0000_0002)
        static let b = Boton(rawValue: 0x0000_0004)
        static let a = Boton(rawValue: 0x0000_0008)
        static let srDerecho = Boton(rawValue: 0x0000_0010)
        static let slDerecho = Boton(rawValue: 0x0000_0020)
        static let r = Boton(rawValue: 0x0000_0040)
        static let zr = Boton(rawValue: 0x0000_0080)
        static let menos = Boton(rawValue: 0x0000_0100)
        static let mas = Boton(rawValue: 0x0000_0200)
        static let stickDerecho = Boton(rawValue: 0x0000_0400)
        static let stickIzquierdo = Boton(rawValue: 0x0000_0800)
        static let home = Boton(rawValue: 0x0000_1000)
        static let captura = Boton(rawValue: 0x0000_2000)
        static let c = Boton(rawValue: 0x0000_4000)
        static let abajo = Boton(rawValue: 0x0001_0000)
        static let arriba = Boton(rawValue: 0x0002_0000)
        static let derecha = Boton(rawValue: 0x0004_0000)
        static let izquierda = Boton(rawValue: 0x0008_0000)
        static let srIzquierdo = Boton(rawValue: 0x0010_0000)
        static let slIzquierdo = Boton(rawValue: 0x0020_0000)
        static let l = Boton(rawValue: 0x0040_0000)
        static let zl = Boton(rawValue: 0x0080_0000)
        static let gr = Boton(rawValue: 0x0100_0000)
        static let gl = Boton(rawValue: 0x0200_0000)
    }

    // MARK: - Utilidades de decodificación

    static func leerU16(_ datos: Data, _ desde: Int) -> UInt16 {
        guard desde + 1 < datos.count else { return 0 }
        return UInt16(datos[datos.startIndex + desde]) | (UInt16(datos[datos.startIndex + desde + 1]) << 8)
    }

    static func leerU32(_ datos: Data, _ desde: Int) -> UInt32 {
        guard desde + 3 < datos.count else { return 0 }
        var valor: UInt32 = 0
        for i in (0..<4).reversed() {
            valor = (valor << 8) | UInt32(datos[datos.startIndex + desde + i])
        }
        return valor
    }

    static func leerI16(_ datos: Data, _ desde: Int) -> Int16 {
        Int16(bitPattern: leerU16(datos, desde))
    }

    /// Descomprime 3 bytes en dos ejes de 12 bits (0..4095).
    static func ejesStick(_ datos: Data, _ desde: Int) -> (x: UInt16, y: UInt16) {
        guard desde + 2 < datos.count else { return (2048, 2048) }
        let b0 = UInt32(datos[datos.startIndex + desde])
        let b1 = UInt32(datos[datos.startIndex + desde + 1])
        let b2 = UInt32(datos[datos.startIndex + desde + 2])
        let valor = b0 | (b1 << 8) | (b2 << 16)
        return (UInt16(valor & 0xFFF), UInt16(valor >> 12))
    }

    /// Construye una trama de comando (protocolo compartido 0x91).
    static func construirComando(_ comando: UInt8, _ subcomando: UInt8, datos: Data = Data()) -> Data {
        var trama = Data([comando, 0x91, 0x01, subcomando, 0x00, UInt8(datos.count), 0x00, 0x00])
        trama.append(datos)
        return trama
    }

    /// Carga útil de una lectura de memoria del mando.
    static func cargaLecturaMemoria(longitud: UInt8, direccion: UInt32) -> Data {
        var datos = Data([longitud, 0x7E, 0x00, 0x00])
        for i in 0..<4 {
            datos.append(UInt8((direccion >> (8 * UInt32(i))) & 0xFF))
        }
        return datos
    }
}

// MARK: - Reporte de entrada

/// Reporte de entrada de 63 bytes de la característica de entrada.
struct ReporteEntrada: Sendable {
    let marcaTiempo: UInt32
    let botones: Protocolo.Boton
    let stickIzquierdoBruto: (x: UInt16, y: UInt16)
    let stickDerechoBruto: (x: UInt16, y: UInt16)
    let bateriaMilivoltios: UInt16
    let acelerometro: (x: Int16, y: Int16, z: Int16)
    let giroscopio: (x: Int16, y: Int16, z: Int16)
    let gatilloIzquierdoBruto: UInt8
    let gatilloDerechoBruto: UInt8

    init?(_ datos: Data) {
        guard datos.count >= 0x20 else { return nil }
        marcaTiempo = Protocolo.leerU32(datos, 0)
        botones = Protocolo.Boton(rawValue: Protocolo.leerU32(datos, 4))
        stickIzquierdoBruto = Protocolo.ejesStick(datos, 10)
        stickDerechoBruto = Protocolo.ejesStick(datos, 13)
        bateriaMilivoltios = Protocolo.leerU16(datos, 0x1F)
        if datos.count >= 0x3C {
            acelerometro = (Protocolo.leerI16(datos, 0x30), Protocolo.leerI16(datos, 0x32), Protocolo.leerI16(datos, 0x34))
            giroscopio = (Protocolo.leerI16(datos, 0x36), Protocolo.leerI16(datos, 0x38), Protocolo.leerI16(datos, 0x3A))
        } else {
            acelerometro = (0, 0, 0)
            giroscopio = (0, 0, 0)
        }
        gatilloIzquierdoBruto = datos.count > 0x3C ? datos[datos.startIndex + 0x3C] : 0
        gatilloDerechoBruto = datos.count > 0x3D ? datos[datos.startIndex + 0x3D] : 0
    }
}

// MARK: - Calibración de sticks

/// Calibración de fábrica o de usuario de un stick analógico.
struct CalibracionStick: Sendable {
    let centro: (x: UInt16, y: UInt16)
    let maximo: (x: UInt16, y: UInt16)
    let minimo: (x: UInt16, y: UInt16)

    /// Calibración neutra por si la lectura falla (rango completo de 12 bits).
    static let porDefecto = CalibracionStick(centro: (2048, 2048), maximo: (2048, 2048), minimo: (2048, 2048))

    init(centro: (x: UInt16, y: UInt16), maximo: (x: UInt16, y: UInt16), minimo: (x: UInt16, y: UInt16)) {
        self.centro = centro
        self.maximo = maximo
        self.minimo = minimo
    }

    init?(datos: Data) {
        guard datos.count >= 9 else { return nil }
        centro = Protocolo.ejesStick(datos, 0)
        maximo = Protocolo.ejesStick(datos, 3)
        minimo = Protocolo.ejesStick(datos, 6)
    }

    /// Normaliza un eje bruto a -1.0…1.0 aplicando la zona muerta indicada.
    private func normalizar(_ bruto: UInt16, centro: UInt16, maximo: UInt16, minimo: UInt16, zonaMuerta: Double) -> Double {
        let desviado = Double(Int(bruto) - Int(centro))
        if desviado > zonaMuerta {
            return maximo > 0 ? min(desviado / Double(maximo), 1.0) : 0
        }
        if desviado < -zonaMuerta {
            return minimo > 0 ? -min(-desviado / Double(minimo), 1.0) : 0
        }
        return 0
    }

    func aplicar(_ bruto: (x: UInt16, y: UInt16), zonaMuerta: Double = 80) -> (x: Double, y: Double) {
        (normalizar(bruto.x, centro: centro.x, maximo: maximo.x, minimo: minimo.x, zonaMuerta: zonaMuerta),
         normalizar(bruto.y, centro: centro.y, maximo: maximo.y, minimo: minimo.y, zonaMuerta: zonaMuerta))
    }
}
