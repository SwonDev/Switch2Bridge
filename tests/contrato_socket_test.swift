import Darwin
import Foundation

/// Caracterización aislada del contrato S2P1.
///
/// Compila las fuentes reales `Rutas.swift`, `Protocolo.swift` y
/// `ServidorEstado.swift` en un ejecutable de prueba. No usa CoreBluetooth, USB,
/// Wine ni el socket real: sólo un socket temporal y clientes POSIX reales.
@main
struct ContratoSocketTest {
    private static let tramaNeutralEsperada = Data([
        0x31, 0x50, 0x32, 0x53, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ])

    static func main() {
        var fallos: [String] = []
        var comprobaciones = 0

        func check(_ bien: Bool, _ nombre: String) {
            comprobaciones += 1
            if !bien { fallos.append(nombre) }
        }

        func comprobarTrama() {
            let estado = EstadoMando(
                botones: 0xDEAD_BEEF,
                ejeIzquierdoX: Int16.min,
                ejeIzquierdoY: -1,
                ejeDerechoX: Int16.max,
                ejeDerechoY: Int16.min,
                gatilloIzquierdo: 17,
                gatilloDerecho: 250,
                conectado: true
            )
            let trama = Array(estado.trama())
            let esperada: [UInt8] = [
                0x31, 0x50, 0x32, 0x53,             // "S2P1" LE
                0xEF, 0xBE, 0xAD, 0xDE,             // máscara LE
                0x00, 0x80,                         // Int16.min
                0xFF, 0xFF,                         // -1
                0xFF, 0x7F,                         // Int16.max
                0x00, 0x80,                         // Int16.min
                0x11, 0xFA, 0x01, 0x00,             // ZL, ZR, conectado, padding
            ]
            check(trama == esperada, "trama: golden little-endian/extremos/gatillos/padding")

            check(EstadoMando().trama() == tramaNeutralEsperada,
                  "trama: desconexión libera botones, ejes y gatillos con padding cero")
        }

        func comprobarMascara() {
            let casos: [(String, Protocolo.Boton, [UInt8])] = [
                ("X", .x, [0x02, 0x00, 0x00, 0x00]),
                ("Y", .y, [0x01, 0x00, 0x00, 0x00]),
                ("Captura", .captura, [0x00, 0x20, 0x00, 0x00]),
                ("C", .c, [0x00, 0x40, 0x00, 0x00]),
                ("GL", .gl, [0x00, 0x00, 0x00, 0x02]),
                ("GR", .gr, [0x00, 0x00, 0x00, 0x01]),
            ]
            for (nombre, boton, bytesEsperados) in casos {
                let trama = EstadoMando(botones: boton.rawValue).trama()
                check(trama.dropFirst(4).prefix(4).elementsEqual(bytesEsperados),
                      "máscara: \(nombre) conserva su posición en el ABI")
            }
        }

        func comprobarServidor(ruta: String) throws {
            let servidor = ServidorEstado(ruta: ruta)
            try servidor.arrancar()

            var info = stat()
            check(stat(ruta, &info) == 0, "socket: existe")
            check((info.st_mode & 0o777) == 0o600, "socket: permiso 0600")

            let cliente1 = try Cliente(ruta: ruta)
            let cliente2 = try Cliente(ruta: ruta)
            let estado1 = EstadoMando(botones: Protocolo.Boton.a.rawValue,
                                      ejeIzquierdoX: -1234, ejeIzquierdoY: 5678,
                                      gatilloIzquierdo: 3, gatilloDerecho: 0, conectado: true)
            let trama1 = Data([
                0x31, 0x50, 0x32, 0x53, 0x08, 0, 0, 0, 0x2E, 0xFB,
                0x2E, 0x16, 0, 0, 0, 0, 0x03, 0, 0x01, 0,
            ])
            check(esperar([cliente1, cliente2], servidor: servidor, estado: estado1,
                          esperada: trama1, timeout: 2.0), "multicliente: dos clientes reciben misma trama")

            cliente1.cerrar()
            cliente2.drenar()
            let estado2 = EstadoMando(botones: Protocolo.Boton.b.rawValue,
                                      ejeDerechoX: 999, ejeDerechoY: -999,
                                      gatilloIzquierdo: 255, gatilloDerecho: 128,
                                      conectado: true)
            let trama2 = Data([
                0x31, 0x50, 0x32, 0x53, 0x04, 0, 0, 0, 0, 0,
                0, 0, 0xE7, 0x03, 0x19, 0xFC, 0xFF, 0x80, 0x01, 0,
            ])
            check(esperar([cliente2], servidor: servidor, estado: estado2,
                          esperada: trama2, timeout: 2.0), "cierre: el otro cliente sigue recibiendo")

            let cliente3 = try Cliente(ruta: ruta)
            check(esperar([cliente2, cliente3], servidor: servidor, estado: estado2,
                          esperada: trama2, timeout: 2.0), "reconexión: nuevo cliente recibe la misma trama")

            let neutral = EstadoMando()
            check(esperar([cliente2, cliente3], servidor: servidor, estado: neutral,
                          esperada: tramaNeutralEsperada, timeout: 2.0), "estado: neutral desconectado 20 bytes")

            cliente2.cerrar()
            cliente3.cerrar()
            servidor.parar()
            check(access(ruta, F_OK) != 0, "parar: elimina el socket")
        }

        comprobarTrama()
        comprobarMascara()
        let ruta = ProcessInfo.processInfo.environment["S2P1_SOCKET"] ?? CommandLine.arguments.dropFirst().first
        if let ruta, !ruta.isEmpty {
            do { try comprobarServidor(ruta: ruta) }
            catch { fallos.append("socket: error \(error)") }
        } else {
            fallos.append("socket: falta S2P1_SOCKET")
        }

        if fallos.isEmpty {
            print("contrato socket: \(comprobaciones) checks, 0 failures")
            exit(0)
        }
        print("contrato socket: \(comprobaciones) checks, \(fallos.count) failures")
        for fallo in fallos { print(" - \(fallo)") }
        exit(1)
    }

    /// Cliente Unix no bloqueante con lectura acotada por `poll`.
    private final class Cliente {
        private var fd: Int32

        init(ruta: String) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ErrorCliente("socket") }
            var direccion = sockaddr_un()
            direccion.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(ruta.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: direccion.sun_path) else {
                close(fd); fd = -1; throw ErrorCliente("ruta demasiado larga")
            }
            withUnsafeMutableBytes(of: &direccion.sun_path) { $0.copyBytes(from: bytes) }
            let resultado = withUnsafePointer(to: &direccion) { puntero in
                puntero.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard resultado == 0 else {
                close(fd); fd = -1; throw ErrorCliente("connect: \(String(cString: strerror(errno)))")
            }
            let banderas = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, banderas | O_NONBLOCK)
        }

        deinit { cerrar() }

        func cerrar() {
            if fd >= 0 { close(fd); fd = -1 }
        }

        func leerTrama(_ tamano: Int, timeout: TimeInterval) -> [UInt8]? {
            var datos: [UInt8] = []
            let limite = Date().addingTimeInterval(timeout)
            while datos.count < tamano {
                let restante = max(0.0, limite.timeIntervalSinceNow)
                if restante <= 0 { return nil }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let listo = poll(&descriptor, 1, Int32(min(restante * 1000, 50)))
                if listo == 0 { continue }
                if listo < 0 { return nil }
                var bloque = [UInt8](repeating: 0, count: tamano - datos.count)
                let leidos = bloque.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if leidos == 0 { return nil }
                if leidos < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    return nil
                }
                datos.append(contentsOf: bloque.prefix(leidos))
            }
            return datos
        }

        func drenar() {
            var bloque = [UInt8](repeating: 0, count: 4096)
            while true {
                let leidos = bloque.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if leidos <= 0 { return }
            }
        }
    }

    private static func esperar(_ clientes: [Cliente], servidor: ServidorEstado,
                                estado: EstadoMando, esperada: Data,
                                timeout: TimeInterval) -> Bool {
        let limite = Date().addingTimeInterval(timeout)
        var recibidas = [Bool](repeating: false, count: clientes.count)
        while Date() < limite {
            servidor.difundir(estado)
            for indice in clientes.indices where !recibidas[indice] {
                if let trama = clientes[indice].leerTrama(EstadoMando.tamanoTrama, timeout: 0.03) {
                    recibidas[indice] = (trama == Array(esperada))
                }
            }
            if recibidas.allSatisfy({ $0 }) { return true }
            usleep(10_000)
        }
        return false
    }
}

private struct ErrorCliente: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
