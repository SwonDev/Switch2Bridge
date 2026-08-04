#ifndef USB_SWITCH2_H
#define USB_SWITCH2_H

/// Inicializa por USB un mando de Switch 2 conmutándolo a modo HID estándar.
///
/// Al conectarse por USB-C el mando arranca en un modo propietario que macOS no
/// reconoce. Esta secuencia de comandos —obtenida por ingeniería inversa de la
/// comunidad— lo hace enumerar como gamepad HID normal, con lo que Steam y
/// cualquier juego lo ven sin necesidad de puente alguno.
///
/// Devuelve 0 si tuvo éxito, o un código negativo:
///   -1 mando no encontrado por USB
///   -2 no se pudo abrir el dispositivo (¿lo tiene otro proceso?)
///   -3 no se encontró la interfaz o el endpoint esperados
///   -4 falló el envío de la secuencia
int switch2_usb_inicializar(void);

/// Indica si hay un mando de Switch 2 conectado por USB (0/1).
int switch2_usb_presente(void);

#endif /* USB_SWITCH2_H */
