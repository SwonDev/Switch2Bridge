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
                      │  socket Unix, tramas S2P1 de 20 bytes
          ┌───────────┴────────────┐
          ▼                        ▼
 libSDL2-2.0.0.dylib       adaptador nativo de Steamac
 (dentro de winedevice)    (copia personalizada, Gamepad.swift)
          │                        │
          ▼                        ▼
 winebus → XInput          pad virtual en el guest SteamOS
```

Una sola fuente de verdad (el demonio) y consumidores que se conectan a su
socket. Añadir un destino nuevo es escribir otro cliente de 20 bytes. El servidor
acepta varios clientes a la vez y cada uno recibe la misma instantánea.

La integración **comprobada por el usuario** en S14 es la copia personalizada
`FX Steam Launcher Switch2Bridge` (Steamac 1.9.13 con la corrección USB upstream
`1c116a36…` y este puente `d7dc2f2`), sobre macOS 27.0.1 / M5 Pro. No se afirma
que la distribución **oficial** de Steamac 1.9.13 haga esto por sí sola, ni que
los juegos nativos de macOS funcionen en general. La ruta de Wine sigue siendo
la de `libSDL2-2.0.0.dylib`; la ruta de Steamac es un consumidor distinto del
mismo socket.

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

> Hubo un segundo consumidor —un inyector SDL2/SDL3 para el Steam de macOS— que
> se retiró: Steam llegaba a reconocer el mando, pero los juegos nativos no
> respondían. El intento queda documentado en
> [`INVESTIGACION.md`](INVESTIGACION.md).

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
| 8 | `i16`×4 | ejes: izq X, izq Y, der X, der Y (−32768…32767) |
| 16 | `u8`×2 | gatillos ZL, ZR (0…255) |
| 18 | `u8` | conectado (0/1) |
| 19 | `u8` | relleno |

La magia permite resincronizar si un cliente se desfasa. Un flujo de socket no
respeta necesariamente los límites de la trama: una lectura puede traer **parte**
de una trama, una trama completa o **varias agrupadas**. El consumidor debe
acumular bytes, localizar la magia y consumir exactamente 20 por trama; no debe
asumir que cada `read` es una instantánea.

El servidor escribe sin bloquear: un cliente atascado pierde tramas en vez de
frenar la entrada. Al desconectarse el mando se emite un latido neutral
(`conectado=0`) cada segundo; el consumidor debe liberar botones/ejes y aceptar
una reconexión posterior. El servidor conserva los demás clientes si uno se
cierra o falla.

El eje Y se invierte: el mando da Y positivo hacia arriba y SDL lo espera hacia
abajo. En el adaptador nativo, X e Y se asignan por **posición física** (X arriba
→ `BTN_WEST`/Y; Y izquierda → `BTN_NORTH`/X), no por el rótulo Nintendo. La
máscara incluye Captura, C, GL y GR; la ruta de emulación Xbox no los expone como
botones, pero sus bits no se pierden en el ABI.

El receptor de la copia Steamac (`Gamepad.swift`) ya tiene su propia suite de
consumo (63 comprobaciones de protocolo y 43 de HID genérico). El contrato de
este repositorio no duplica esa suite: comprueba el ABI y el servidor.

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

## Ruta USB-C

`daemon/Sources/USBSwitch2/usb_switch2.c`

Busca el dispositivo por VID/PID con IOKit, abre la **interfaz 1**, localiza su
endpoint bulk de salida y envía 17 comandos con 50 ms de separación. El mando
pasa entonces a **modo HID estándar** y macOS lo publica como gamepad real.

`VigilanteUSB` lo vigila cada 3 segundos y sólo actúa en la transición
«ausente → presente», para no reintentar en bucle. Que `USBDeviceOpen` falle no
es error: normalmente significa que macOS ya lo reclamó como HID.

Para el consumidor de Steamac, `supportsHIDDevice == true` (o ver el dispositivo
en IOKit) **no demuestra** que GameController lo haya publicado: la corrección
upstream espera 2 s a que exista un `GCController` coincidente y, si no aparece,
lo admite como HID genérico. El passthrough necesita un dispositivo HID real
enumerado por IOKit y sus reportes; no exige que GameController lo publique
ni puede deducirse únicamente del booleano de soporte.

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

La copia de Steamac usa actualizaciones por reconstrucción local: prepara una
candidata fuera de la app activa, verifica antes de sustituir y conserva la
versión anterior con backups. Ese mecanismo es fail-closed: un conflicto,
firma/hash incorrectos o pruebas fallidas conservan la copia instalada. No hay
que congelar las actualizaciones ni desactivarlas para mantener el puente; sus
recursos se incluyen en la copia y en la caché autorizada.

---

## Verificar el contrato aislado

El contrato S2P1 se puede comprobar sin instalar, sin arrancar el daemon y sin
tocar Bluetooth, USB, Wine ni el socket real:

```bash
./tests/contrato_socket_test.sh
```

El script compila `Rutas.swift`, `Protocolo.swift`,
`ServidorEstado.swift` y `tests/contrato_socket_test.swift` en un ejecutable
temporal; usa un socket temporal de menos de 104 bytes, con `HOME` aislado, y
lo elimina al terminar. Verifica la trama golden de 20 bytes, la máscara
X/Y/Captura/C/GL/GR, permiso `0600`, dos clientes con la misma instantánea,
cierre de un cliente sin cortar al otro, reconexión, estado neutral y limpieza
con `parar()`. No conecta con `~/Library/Application Support/Switch2Bridge/estado.sock`.
