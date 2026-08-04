import Dispatch
import Foundation
import OSLog

/// Rutas compartidas por el demonio, la shim de SDL y los scripts.
enum RutasPuente {
    /// Carpeta de soporte del puente dentro del directorio del usuario.
    static var soporte: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Switch2Bridge")
    }

    /// Socket Unix por el que se difunde el estado del mando.
    ///
    /// Debe coincidir con `RUTA_SOCKET` de `shim_sdl.c`.
    static var socket: String {
        (soporte as NSString).appendingPathComponent("estado.sock")
    }
}

/// Retenedor de las fuentes de señal: si se liberan, dejan de dispararse.
nonisolated(unsafe) var fuentesSenal: [DispatchSourceSignal] = []

/// Traza dual: al registro unificado y a la salida estándar.
///
/// launchd redirige la salida a `salida.log`, así que el diagnóstico queda en un
/// fichero legible sin necesidad de abrir Consola.
struct Registro: Sendable {
    private let sistema: Logger
    private let categoria: String

    init(categoria: String) {
        self.categoria = categoria
        self.sistema = Logger(subsystem: "dev.swondev.switch2bridge", category: categoria)
    }

    private func escribir(_ nivel: String, _ mensaje: String) {
        let ahora = Date().formatted(.dateTime.hour().minute().second())
        print("[\(ahora)] \(nivel) \(categoria): \(mensaje)")
    }

    func info(_ mensaje: String) {
        sistema.info("\(mensaje, privacy: .public)")
        escribir("·", mensaje)
    }

    func aviso(_ mensaje: String) {
        sistema.warning("\(mensaje, privacy: .public)")
        escribir("⚠", mensaje)
    }

    func error(_ mensaje: String) {
        sistema.error("\(mensaje, privacy: .public)")
        escribir("✗", mensaje)
    }
}
