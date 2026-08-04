import Darwin
import Foundation
import OSLog

/// Estado normalizado del mando que se difunde a los consumidores.
struct EstadoMando: Sendable {
    var botones: UInt32 = 0
    /// Ejes en el rango de SDL: -32768…32767. Y positivo hacia abajo.
    var ejeIzquierdoX: Int16 = 0
    var ejeIzquierdoY: Int16 = 0
    var ejeDerechoX: Int16 = 0
    var ejeDerechoY: Int16 = 0
    var gatilloIzquierdo: UInt8 = 0
    var gatilloDerecho: UInt8 = 0
    var conectado: Bool = false

    static let tamanoTrama = 20
    static let magia: UInt32 = 0x5332_5031  // "S2P1"

    /// Serializa a la trama binaria de 20 bytes que consume la shim de SDL.
    func trama() -> Data {
        var datos = Data(capacity: Self.tamanoTrama)
        func u16(_ v: UInt16) { datos.append(UInt8(v & 0xFF)); datos.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
        u32(Self.magia)
        u32(botones)
        u16(UInt16(bitPattern: ejeIzquierdoX))
        u16(UInt16(bitPattern: ejeIzquierdoY))
        u16(UInt16(bitPattern: ejeDerechoX))
        u16(UInt16(bitPattern: ejeDerechoY))
        datos.append(gatilloIzquierdo)
        datos.append(gatilloDerecho)
        datos.append(conectado ? 1 : 0)
        datos.append(0)  // relleno
        return datos
    }
}

/// Servidor de sockets Unix que difunde el estado del mando.
///
/// Acepta varios clientes a la vez (la shim de SDL dentro de Wine, herramientas
/// de diagnóstico, etc.). Escribe sin bloquear: si un cliente se atasca se
/// descarta en lugar de frenar la ruta de entrada.
final class ServidorEstado: @unchecked Sendable {
    private let registro = Registro(categoria: "socket")
    private let ruta: String
    private var descriptorEscucha: Int32 = -1
    private var clientes: [Int32] = []
    private let cola = DispatchQueue(label: "dev.swondev.switch2bridge.socket")
    private var fuenteAceptar: DispatchSourceRead?

    init(ruta: String) {
        self.ruta = ruta
    }

    func arrancar() throws {
        // Crea el directorio contenedor y limpia un socket huérfano previo.
        let directorio = (ruta as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directorio, withIntermediateDirectories: true)
        unlink(ruta)

        descriptorEscucha = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptorEscucha >= 0 else {
            throw ErrorPuente.socket("no se pudo crear el socket: \(String(cString: strerror(errno)))")
        }

        var direccion = sockaddr_un()
        direccion.sun_family = sa_family_t(AF_UNIX)
        let rutaBytes = Array(ruta.utf8)
        guard rutaBytes.count < MemoryLayout.size(ofValue: direccion.sun_path) else {
            throw ErrorPuente.socket("la ruta del socket es demasiado larga")
        }
        withUnsafeMutableBytes(of: &direccion.sun_path) { destino in
            destino.copyBytes(from: rutaBytes)
        }

        let longitud = socklen_t(MemoryLayout<sockaddr_un>.size)
        let resultado = withUnsafePointer(to: &direccion) { puntero in
            puntero.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(descriptorEscucha, sa, longitud)
            }
        }
        guard resultado == 0 else {
            throw ErrorPuente.socket("bind falló: \(String(cString: strerror(errno)))")
        }
        guard listen(descriptorEscucha, 8) == 0 else {
            throw ErrorPuente.socket("listen falló: \(String(cString: strerror(errno)))")
        }
        // Sólo el usuario puede conectarse.
        chmod(ruta, 0o600)

        let fuente = DispatchSource.makeReadSource(fileDescriptor: descriptorEscucha, queue: cola)
        fuente.setEventHandler { [weak self] in self?.aceptarCliente() }
        fuente.resume()
        fuenteAceptar = fuente

        registro.info("servidor de estado escuchando en \(self.ruta)")
    }

    private func aceptarCliente() {
        let cliente = accept(descriptorEscucha, nil, nil)
        guard cliente >= 0 else { return }
        // Sin bloqueo y sin SIGPIPE: un cliente muerto no debe tumbar el demonio.
        var uno: Int32 = 1
        setsockopt(cliente, SOL_SOCKET, SO_NOSIGPIPE, &uno, socklen_t(MemoryLayout<Int32>.size))
        let banderas = fcntl(cliente, F_GETFL, 0)
        _ = fcntl(cliente, F_SETFL, banderas | O_NONBLOCK)
        clientes.append(cliente)
        registro.info("cliente conectado (total: \(self.clientes.count))")
    }

    /// Difunde el estado a todos los clientes conectados.
    func difundir(_ estado: EstadoMando) {
        let trama = estado.trama()
        cola.async { [weak self] in
            guard let self else { return }
            guard !self.clientes.isEmpty else { return }
            var vivos: [Int32] = []
            for cliente in self.clientes {
                let enviados = trama.withUnsafeBytes { bufer -> Int in
                    send(cliente, bufer.baseAddress, bufer.count, 0)
                }
                if enviados == trama.count {
                    vivos.append(cliente)
                } else if enviados < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // Cliente lento: conservamos la conexión y descartamos esta trama.
                    vivos.append(cliente)
                } else {
                    close(cliente)
                    self.registro.info("cliente desconectado")
                }
            }
            self.clientes = vivos
        }
    }

    func parar() {
        fuenteAceptar?.cancel()
        for cliente in clientes { close(cliente) }
        clientes.removeAll()
        if descriptorEscucha >= 0 { close(descriptorEscucha) }
        unlink(ruta)
    }
}

enum ErrorPuente: Error, CustomStringConvertible {
    case socket(String)
    case bluetooth(String)
    case tiempoAgotado(String)

    var description: String {
        switch self {
        case .socket(let m): return "socket: \(m)"
        case .bluetooth(let m): return "bluetooth: \(m)"
        case .tiempoAgotado(let m): return "tiempo agotado: \(m)"
        }
    }
}
