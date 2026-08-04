# Cómo funciona por dentro

Arquitectura y decisiones de diseño. Para el *porqué* histórico y las pruebas,
ver [`INVESTIGACION.md`](INVESTIGACION.md).

---

## Visión general

```
              Pro Controller 2
                    │  BLE · GATT propietario
                    ▼
      ┌───────────────────────────────┐
      │      Switch2Bridge.app        │   demonio Swift 6, sin interfaz
      │  CoreBluetooth · saludo       │   arranca con la sesión (LaunchAgent)
      │  calibración · reportes 29 Hz │
      └───────────────┬───────────────┘
                      │  socket Unix, tramas de 20 bytes
          ┌───────────┴────────────┐
          ▼                        ▼
  libSDL2-2.0.0.dylib        inyector.dylib
  (dentro de winedevice)     (dentro de steam_osx y sus hijos)
          │                        │
          ▼                        ▼
  winebus → HID XInput       Steam → Steam Input → juego nativo
```

Una sola fuente de verdad (el demonio) y varios consumidores que se conectan a
su socket. Añadir un destino nuevo es escribir otro cliente de 20 bytes.

---

## El demonio

`daemon/Sources/Switch2Bridge/`

| Fichero | Responsabilidad |
|---|---|
| `Protocolo.swift` | UUIDs, comandos, decodificación de reportes, calibración |
| `SesionMando.swift` | sesión BLE con CoreBluetooth y saludo del protocolo |
| `ServidorEstado.swift` | servidor de sockets Unix y serialización |
| `VigilanteUSB.swift` | detección del cable y conmutación a HID |
| `Rutas.swift` | rutas compartidas y traza dual (OSLog + fichero) |
| `USBSwitch2/usb_switch2.c` | secuencia USB con IOKit (en C por las interfaces COM) |

### Decisiones que importan

**Todo en la cola serie de CoreBluetooth.** Los objetos de CoreBluetooth no son
`Sendable`. En lugar de pelearse con la concurrencia estricta de Swift 6,
`enviarComando` hace todo su trabajo en la cola del central, y el temporizador de
seguridad se identifica por número de secuencia para que el vencimiento de un
comando antiguo no cancele al siguiente.

**Doble red en la reconexión.** Al desconectar se piden a la vez una conexión
pendiente (se dispara sola cuando el mando despierta) y un escaneo. Sólo con la
conexión pendiente el puente se quedaba ciego si el mando volvía con otra
identidad; sólo con el escaneo se gastaba radio de más. Al conectar, se para el
escaneo.

**Latido de estado.** Si no llegan reportes, se emite una trama «desconectado»
cada segundo. Sin eso, las herramientas de diagnóstico se quedaban bloqueadas
esperando datos que no iban a llegar, y parecía un cuelgue.

**Traza a fichero además de OSLog.** Las trazas `info` de OSLog no salen en
`log show` sin `--info`, lo que hacía imposible diagnosticar. El demonio escribe
también a `salida.log`.

**Volcado de reportes crudos.** `reportes.log` registra los bytes del mando
cuando **cambia la máscara de botones** (ignorando el ruido de los sticks, que
llenaría el fichero en un segundo). Cada línea es una pulsación real: permite
distinguir «el mando no manda» de «nosotros decodificamos mal».

---

## Formato del socket

20 bytes, little-endian, una trama por reporte:

| Offset | Tipo | Campo |
|---|---|---|
| 0 | `u32` | magia `0x53325031` (`"S2P1"`) |
| 4 | `u32` | máscara de botones del mando |
| 8 | `i16`×4 | ejes: izq X, izq Y, der X, der Y (−32767…32767) |
| 16 | `u8`×2 | gatillos ZL, ZR (0…255) |
| 18 | `u8` | conectado (0/1) |
| 19 | `u8` | relleno |

La magia permite resincronizar si un cliente se desfasa. El servidor escribe sin
bloquear: un cliente atascado pierde tramas en vez de frenar la entrada.

El eje Y se invierte: el mando da Y positivo hacia arriba y SDL lo espera hacia
abajo.

---

## Shim de SDL para Wine

`shim/shim_sdl.c` → se instala como `libSDL2-2.0.0.dylib` en
`<runtime>/lib/wine/x86_64-unix/`.

**Por qué ahí:** `winebus.so` hace `dlopen("libSDL2-2.0.0.dylib")` con nombre
suelto y su primer `LC_RPATH` es `@loader_path/`, es decir ese mismo directorio.
Gana a la copia propia del runtime.

**Por qué reexporta:** se llama igual que la SDL real, así que sustituirla a
secas dejaría a Wine sin SDL. Se enlaza con `-Wl,-reexport_library` contra una
**copia** de la SDL original guardada en la carpeta de soporte. Así expone la API
completa y además añade nuestro joystick.

**Qué hace:** un constructor lanza un hilo que espera a que Wine inicialice el
subsistema de joysticks, da de alta un joystick virtual con
`SDL_JoystickAttachVirtualEx` (fabricante `0x057E`, producto `0x2069`), publica
un mapeo de gamepad completo con `SDL_GameControllerAddMapping` y luego alimenta
ejes y botones desde el socket.

**Por qué el mapeo explícito:** sin él Wine lo trataría como joystick genérico en
vez de como gamepad, y se perdería la equivalencia con XInput.

**Requisito adicional:** `Enable SDL = 1` en
`HKLM\System\CurrentControlSet\Services\winebus\Parameters` de cada botella.
CrossOver lo trae desactivado en macOS.

---

## Inyector para Steam y juegos nativos

`shim/inyector.c` → `~/Library/Application Support/Switch2Bridge/inyector.dylib`

Se carga con `DYLD_INSERT_LIBRARIES` desde el lanzador **«Steam con mando»**,
que arranca el `steam_osx` **interno** (el de `Application Support`), el único
sin *hardened runtime*. Los procesos hijos heredan la variable, así que los
juegos que use SDL también lo reciben.

**Se adapta solo.** Resuelve símbolos con `dlsym(RTLD_DEFAULT, …)`: si encuentra
la API de SDL3 la usa, si no prueba con SDL2, y si no hay ninguna **se retira sin
hacer nada**. Eso es lo que lo hace seguro de heredar en procesos ajenos.

**El sondeo de SDL3.** SDL3 versiona sus interfaces *por tamaño*: el campo
`version` del descriptor debe valer `sizeof(SDL_VirtualJoystickDesc)`. En vez de
fijar una constante que envejecería con cada versión de SDL, el inyector prueba
tamaños de 64 a 240 y valida el acierto contando los ejes del joystick creado.
Con la SDL3 que trae Steam hoy, sale 136.

**Por qué hace falta Steam Input.** Motores como Unity leen por `IOHIDManager` y
`GCController`, no por SDL, y sólo convierten en `Gamepad` los dispositivos de
su base de datos. Un mando desconocido queda como joystick genérico y el juego
lo ignora — incluso siendo un HID real, verificado por cable. Steam sí lo
reconoce, y Steam Input se lo entrega al juego traducido. De ahí que activarlo
por juego sea obligatorio.

---

## Ruta USB-C

`daemon/Sources/USBSwitch2/usb_switch2.c`

Busca el dispositivo por VID/PID con IOKit, abre la **interfaz 1**, localiza su
endpoint bulk de salida y envía 17 comandos con 50 ms de separación. El mando
pasa entonces a **modo HID estándar** y macOS lo publica como gamepad real.

`VigilanteUSB` lo vigila cada 3 segundos y sólo actúa en la transición
«ausente → presente», para no reintentar en bucle. Que `USBDeviceOpen` falle no
es error: normalmente significa que macOS ya lo reclamó como HID.

Está en C porque las interfaces de IOKit son de estilo COM (punteros a tablas de
funciones) y en Swift resultan mucho más farragosas.

---

## Instalación y reversibilidad

`instalar.sh` es idempotente y detecta **cualquier** runtime de Wine instalado
(CrossOver, Wine oficial, empaquetados propios…): busca
`lib/wine/x86_64-unix/winebus.so` siguiendo enlaces simbólicos, comprueba que
haya una `libSDL2` x86_64 que reexportar y deduplica por ruta real.

Nada se sobrescribe: dentro de los bundles ajenos sólo se **añade** un fichero,
que `desinstalar.sh` retira. El valor `Enable SDL` se deja puesto por inocuo.

`verificar.sh` recorre la cadena entera y señala el eslabón roto con la orden
concreta para arreglarlo.
