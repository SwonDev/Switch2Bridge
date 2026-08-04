import Foundation
import OSLog

/// Punto de entrada del demonio.
///
/// Se ejecuta sin interfaz (LSUIElement) como agente de arranque: conecta el
/// mando por BLE y difunde su estado por un socket Unix.
let registroPrincipal = Registro(categoria: "principal")

setvbuf(stdout, nil, _IONBF, 0)

let rutaSocket = RutasPuente.socket

let servidor = ServidorEstado(ruta: rutaSocket)
do {
    try servidor.arrancar()
} catch {
    registroPrincipal.error("no se pudo abrir el socket: \(String(describing: error))")
    exit(1)
}

let sesion = SesionMando(servidor: servidor)

// Ruta USB-C: independiente del Bluetooth y complementaria a él.
let vigilanteUSB = VigilanteUSB()
vigilanteUSB.arrancar()

// Cierre limpio del socket ante SIGTERM/SIGINT (launchd usa SIGTERM).
for senal in [SIGTERM, SIGINT] {
    signal(senal, SIG_IGN)
    let fuente = DispatchSource.makeSignalSource(signal: senal, queue: .main)
    fuente.setEventHandler {
        registroPrincipal.info("cerrando")
        servidor.parar()
        exit(0)
    }
    fuente.resume()
    fuentesSenal.append(fuente)
}

registroPrincipal.info("Switch2Bridge en marcha")
RunLoop.main.run()
