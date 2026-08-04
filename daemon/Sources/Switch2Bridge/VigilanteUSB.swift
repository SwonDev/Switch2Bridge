import Foundation
import USBSwitch2

/// Vigila la conexión del mando por USB-C y lo conmuta a modo HID estándar.
///
/// En cuanto la secuencia surte efecto, macOS enumera el mando como gamepad
/// normal: lo ven Steam, los juegos nativos y también Wine a través de su bus
/// IOHID, sin necesidad del puente Bluetooth.
final class VigilanteUSB: @unchecked Sendable {
    private let registro = Registro(categoria: "usb")
    private let cola = DispatchQueue(label: "dev.swondev.switch2bridge.usb")
    private var temporizador: DispatchSourceTimer?

    /// Evita reintentar sin fin mientras el mando siga enchufado.
    private var yaAtendido = false

    func arrancar() {
        let t = DispatchSource.makeTimerSource(queue: cola)
        t.schedule(deadline: .now() + 2, repeating: 3)
        t.setEventHandler { [weak self] in self?.revisar() }
        t.resume()
        temporizador = t
    }

    private func revisar() {
        let presente = switch2_usb_presente() == 1

        guard presente else {
            // Al desenchufarlo, rearmamos para la próxima conexión.
            if yaAtendido {
                registro.info("mando USB desconectado")
                yaAtendido = false
            }
            return
        }

        guard !yaAtendido else { return }
        yaAtendido = true

        registro.info("mando detectado por USB; enviando secuencia de inicialización")
        switch switch2_usb_inicializar() {
        case 0:
            registro.info("mando conmutado a modo HID: ya debería verse como gamepad en Steam")
        case -1:
            registro.aviso("el mando desapareció antes de poder inicializarlo")
        case -2:
            // Lo normal si macOS ya lo reclamó como HID: no es un error.
            registro.info("el mando ya está en modo HID (o lo usa otro proceso)")
        case -3:
            registro.aviso("no se encontró la interfaz de comandos esperada")
        case -4:
            registro.aviso("falló el envío de la secuencia de inicialización")
        default:
            registro.aviso("resultado desconocido al inicializar por USB")
        }
    }
}
