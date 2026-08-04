# La investigación

Este documento existe para que, si algo deja de funcionar, no haya que rehacer
el camino. Recoge **qué se probó, qué devolvió cada prueba y por qué se
descartó**. Todo lo que aparece aquí se ejecutó en el equipo real
(MacBook Pro M5 Pro, macOS 26.5, 4 de agosto de 2026), no es teoría.

---

## 1. El punto de partida

El Nintendo Switch 2 Pro Controller no funciona en macOS. La creencia extendida
—y lo que responden los asistentes de IA— es que «no es compatible». La pregunta
real es **por qué**, y la respuesta tiene dos capas independientes.

### Capa 1: el mando no habla HID por Bluetooth

Los mandos de Switch 2 usan Bluetooth LE con un **servicio GATT propietario**.
Volcado real de su tabla GATT (`gatt.log`):

```
SERVICIO 00C5AF5D-1964-4E30-8F51-1956F96BD280
   · …281 [read]   · …282 [write]   · …283 [read]
SERVICIO AB7DE9BE-89FE-49AD-828F-118F09DF7FD0
   · AB7DE9BE-…-118F09DF7FD2  [read,notify]   ← reportes de entrada
   · 649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005  [writeSinResp]  ← comandos
   · C765A961-D9D8-4D36-A20A-5315B111836A  [notify]        ← respuestas
   · CC483F51-9258-427D-A939-630C31F72B05  [writeSinResp]  ← vibración HD
   · (y otras propietarias)
```

**No existe el servicio HID estándar `0x1812`.** Por tanto macOS no puede
adoptarlo por sí solo: no hay nada que adoptar. Esto descarta de raíz cualquier
esperanza de «que se empareje bien y ya».

### Capa 2: macOS no deja crear un mando virtual

La solución obvia sería leer el mando nosotros y publicar un HID virtual para
todo el sistema. macOS lo impide.

---

## 2. El muro de Apple, con pruebas

### 2.1 CoreHID existe y es API pública

`CoreHID.framework` incluye desde macOS 15 un `HIDVirtualDevice` público:

```swift
@available(macOS 15, *)
public actor HIDVirtualDevice {
    public init?(properties: HIDVirtualDevice.Properties)
    public func activate(delegate: any HIDVirtualDeviceDelegate)
    public func dispatchInputReport(data: Data, timestamp: SuspendingClock.Instant) async throws
}
```

Parece la respuesta. No lo es.

### 2.2 Sin entitlement devuelve nil

```
❌ FALLO: HIDVirtualDevice(properties:) devolvió nil
```

### 2.3 Con entitlement, AMFI mata el proceso

Firmando ad-hoc con `com.apple.developer.hid.virtual.device`:

```
exit code 137   ← SIGKILL
```

Y firmando con un certificado **Apple Development real** (de una cuenta de
desarrollador gratuita), mismo resultado: SIGKILL. El entitlement es
*restringido*: exige un perfil de aprovisionamiento autorizado por Apple.

### 2.4 El segundo entitlement tampoco

El kernel acepta dos. Del código fuente de IOHIDFamily:

```cpp
// IOHIDResourceUserClient.cpp
#define kIOHIDManagerUserAccessUserDeviceEntitlement "com.apple.hid.manager.user-access-device"
#define kIOHIDVirtualDeviceEntitlement               "com.apple.developer.hid.virtual.device"

// initWithTask:
entitlement = copyClientEntitlement(owningTask, kIOHIDManagerUserAccessUserDeviceEntitlement);
if (entitlement) result = (entitlement == kOSBooleanTrue);
if (!result) {
    entitlement = copyClientEntitlement(owningTask, kIOHIDVirtualDeviceEntitlement);
    if (entitlement) result = (entitlement == kOSBooleanTrue);
}
```

`com.apple.hid.manager.user-access-device` firmado ad-hoc: **SIGKILL** también.

**Consecuencia importante:** la comprobación es *puramente de entitlements*. No
hay respaldo por privilegios, así que **ejecutar como root no sirve de nada** y
un LaunchDaemon tampoco. No hace falta ni probarlo.

### 2.5 Los permisos de TCC no son la vía

Con Accesibilidad y Monitorización de entrada concedidas:

```
AXIsProcessTrusted: true
IOHIDCheckAccess(postEvent)   = GRANTED
IOHIDCheckAccess(listenEvent) = GRANTED
❌ IOHIDUserDeviceCreateWithProperties devolvió nil    (IOServiceOpen:0xe00002c2)
```

### 2.6 DriverKit exige desactivar SIP

```
$ csrutil status
System Integrity Protection status: enabled.

$ systemextensionsctl developer on
At this time, this tool cannot be used if System Integrity Protection is enabled.
```

Y el entitlement de familia HID de DriverKit es una *managed capability* que
requiere el Apple Developer Program de pago más aprobación manual de Apple.

### 2.7 Confirmación externa

- `switch2bridge-macos` documenta en su tabla: **«Native HID: ❌ Not possible —
  Would require DriverKit»**.
- Sam Lantinga, autor de SDL, sobre este mismo mando en macOS: *«You need to get
  special permissions from Apple to access raw USB controllers. I haven't managed
  to do this yet.»*
- El repo `cannt/VirtualGamepad` anota en su propio fichero de entitlements:
  *«NOTE: This entitlement requires Apple approval»*, y acabó resolviéndolo con
  un modo hardware del mando.

**Conclusión de esta fase:** publicar un mando virtual para todo el sistema es
imposible sin bendición de Apple. Hay que rodear el muro.

---

## 3. Rodeo 1 — Wine (juegos de Windows)

### 3.1 El hallazgo

`winebus.so` de CrossOver tiene compilado el bus SDL además del de IOHID:

```
$ strings winebus.so | grep -E "bus_init"
iohid_bus_init
sdl_bus_init        ← existe
udev_bus_init
xbox_bus_init
```

Y carga SDL **por nombre suelto**:

```
$ otool -tV winebus.so | grep -B2 dlopen
leaq  …  ## literal pool for: "libSDL2-2.0.0.dylib"
callq …  ## symbol stub for: _dlopen
```

Sus rpaths, por orden:

```
$ otool -l winebus.so | grep -A2 LC_RPATH
path @loader_path/                    ← el primero
path @loader_path/../lib64
path @loader_path/../../../lib64
```

**Colocando nuestra biblioteca en `@loader_path/` gana la precedencia.**

### 3.2 Los dos obstáculos que costaron tiempo

**a) El bus SDL viene desactivado.** El PE `winebus.sys` contiene la cadena
*«SDL devices disabled in registry»* y lee la opción `Enable SDL` (nombre exacto,
en UTF-16 dentro del binario) de:

```
HKLM\System\CurrentControlSet\Services\winebus\Parameters
```

CrossOver la trae a 0 en macOS. Hay que ponerla a 1.

**b) `wineserver -k` NO mata la sesión.** Se perdieron dos pruebas enteras
creyendo que la shim no cargaba, cuando lo que ocurría es que `winedevice.exe`
seguía vivo con los mismos PID y nunca repetía el `dlopen`. Lo que funciona:

```bash
pkill -f winedevice; pkill -f wineserver
```

### 3.3 La prueba que lo confirmó

```
[17:46:23] CARGADA por pid=93426 ejecutable=…/winedevice.exe
```

y después, dentro de la botella de Windows:

```
HKEY_LOCAL_MACHINE\System\CurrentControlSet\Enum\HID\VID_057E&PID_2069&IG_00
HKEY_LOCAL_MACHINE\System\CurrentControlSet\Enum\HID\VID_057E&PID_2069&XI_00
                                                                    ↑ XInput
```

`XI_00` significa que Wine lo publicó como **gamepad XInput**, que es lo que
esperan los juegos de Windows.

### 3.4 Detalle: por qué reexportamos

La shim se llama igual que la SDL real. Si sólo la sustituyéramos, CrossOver
perdería SDL. La solución es enlazar con `-Wl,-reexport_library` contra una
**copia** de la SDL original guardada fuera del bundle: así la shim expone la API
completa (verificado con `dlsym` sobre `SDL_Init`, `SDL_JoystickOpen`,
`SDL_GameControllerAddMapping`, `SDL_WaitEventTimeout`) y además añade nuestro
joystick virtual.

---

## 4. Rodeo 2 — Steam para macOS (juegos nativos): INTENTADO Y DESCARTADO

> **Resultado: no funciona.** Todo lo técnico de este apartado se logró —Steam
> llega a reconocer el mando— pero **en los juegos nativos no responde**, así que
> la vía se retiró del proyecto. Se documenta para que nadie la repita creyendo
> que es un camino abierto.

### 4.1 El hallazgo

Hay **dos** binarios de Steam y no son iguales:

| Binario | Hardened runtime |
|---|---|
| `/Applications/Steam.app/Contents/MacOS/steam_osx` | sí (`flags=0x10000`) |
| `~/Library/Application Support/Steam/.../MacOS/steam_osx` | **no** (`flags=0x0`) |

El segundo —el que de verdad ejecuta Steam— **admite
`DYLD_INSERT_LIBRARIES`**. Y su `libSDL3.dylib` exporta la API completa de
joystick virtual:

```
$ nm -gU libSDL3.dylib | grep Virtual
_SDL_AttachVirtualJoystick
_SDL_DetachVirtualJoystick
_SDL_SetJoystickVirtualAxis
_SDL_SetJoystickVirtualButton
_SDL_SetJoystickVirtualHat
```

### 4.2 La trampa de SDL3

`SDL_AttachVirtualJoystick` devolvía 0 (fallo) una y otra vez. Motivo: **SDL3
versiona sus interfaces por TAMAÑO, no por número**. El campo `version` del
descriptor debe valer `sizeof(SDL_VirtualJoystickDesc)`, no `1` como en SDL2.

En vez de fijar una constante que envejecería mal, el inyector **sondea** el
tamaño y valida el resultado contando los ejes del mando creado:

```
SDL3: joystick virtual dado de alta (id 2, sizeof desc = 136)
```

136 para esta versión de SDL3; si Valve actualiza SDL, el sondeo se adapta solo.

### 4.3 Steam lo reconoce

```
[19:01:51] Controller 0 connected, configuring it now...
[19:01:51] !! Controller 0 attributes:
  Type: 51
  ProductID: 8297             ← 0x2069
  Serial: 57e-2069-73833de    ← VID Nintendo 0x057E
```

### 4.4 El obstáculo de fondo: los motores nativos

Aun con todo lo anterior, **Vampire Crawlers (Unity) seguía sin responder**.
Diagnóstico:

```
$ otool -L UnityPlayer.dylib | grep -E "GameController|IOKit"
  /System/Library/Frameworks/IOKit.framework/…
  /System/Library/Frameworks/GameController.framework/…
```

Unity lee por `IOHIDManager` y `GCController`, no por SDL. Y aunque el mando
esté presente como HID real (probado por cable), **Unity sólo convierte en
`Gamepad` los dispositivos de su base de datos interna**; a los desconocidos los
deja como joystick genérico y el juego los ignora.

La solución es **Steam Input**: Steam sí reconoce el mando (real o virtual) y se
lo entrega al juego traducido.

### 4.5 Por qué se descartó

Con el inyector activo, Steam listaba el mando, pero **los juegos nativos no
respondían**. Probado además por cable, donde el mando es un HID real del
sistema: los motores lo detectan **mal y con errores**, porque su descriptor es
atípico (ejes `Rx`/`Rz` para el stick derecho, sin *hat*, 21 botones sin
correspondencia estándar).

Y `GameController.framework` no lo adopta en absoluto: con el mando conectado
por cable, `GCController.controllers()` devuelve vacío. Apple sólo expone ahí los
mandos de su lista blanca.

Conclusión: para juegos nativos haría falta un HID virtual del sistema —el
entitlement bloqueado— o hardware que se presentase como un mando ya conocido.

### 4.6 Qué sí se confirmó

La validación final se hizo **en la ruta de Wine**, no en la nativa:

1. Se arrancó un launcher propio basado en Wine, que abrió el **Steam de
   Windows** dentro de su botella.
2. En ese Steam se detectó el mando **como mando de Switch Pro** y se mapearon
   los controles desde las opciones de mando, guardando la configuración.
3. Se lanzó **Dragonsword Awakening** y respondió perfectamente, con el cable
   puesto.
4. Se desenchufó el cable, se volvió a lanzar el juego y **siguió funcionando,
   sólo por Bluetooth**.

Eso confirma de punta a punta la cadena
`BLE → demonio → shim de SDL en Wine → winebus → gamepad XInput → juego`.

La ruta nativa de macOS se descartó tras comprobar en un juego que no funciona
(ver 4.5).

---

## 5. Ruta USB-C

Por cable el mando arranca en un modo propietario. Una secuencia de 17 comandos
sobre el endpoint bulk de la interfaz 1 lo conmuta a **HID estándar**. Resultado
verificado:

```
hidutil →  0x57e 0x2069 USB AppleUserHIDDevice "Pro Controller"
IOHIDManager → usage 1/5 = GAME PAD · 4 ejes · 21 botones
Eventos reales capturados: 251 pulsaciones de botón + ejes con valores
                           X=1987 Y=2158 Rx=2130 Rz=2088
```

Descriptor HID decodificado (97 bytes):

```
Report ID 5 → 63 bytes propietarios (telemetría)
Report ID 9 → 21 botones (1 bit) + 4 ejes de 12 bits (X, Y, Rx, Rz), rango 0…4095
Report ID 2 → salida, 63 bytes
```

Nota: los ejes del stick derecho son **Rx y Rz**, no los habituales Z/Rz. Algún
juego podría no mapearlos por su cuenta. Dentro de Wine no importa, porque el
gamepad se publica ya normalizado como XInput.

---

## 6. Callejones sin salida (para no repetirlos)

| Idea | Por qué no |
|---|---|
| Ejecutar el demonio como root o LaunchDaemon | el kernel sólo mira entitlements |
| Conceder Accesibilidad / Monitorización de entrada | no interviene en la creación de HID |
| `com.apple.hid.manager.user-access-device` | AMFI lo mata igual |
| DriverKit en modo desarrollador | exige SIP desactivado |
| Que el mando exponga HID-over-GATT | no tiene el servicio 0x1812 |
| Que la Mac se conecte a sí misma por BLE como periférico HID | un radio Bluetooth no puede conectarse consigo mismo |
| `DYLD_LIBRARY_PATH` para colar la shim en Wine | `wineloader` tiene hardened runtime y las variables DYLD se eliminan |
| Poner la shim en `~/lib` | los `LC_RPATH` del llamante ganan a las rutas de reserva de dyld |
| Inyectar en juegos con hardened runtime | macOS lo impide |
| Inyectar un joystick SDL en el Steam de macOS | Steam lo reconoce, pero los juegos nativos no responden |

---

## 7. Trampas de entorno que costaron tiempo

- **`wineserver -k` no mata la sesión.** Usar `pkill -f winedevice; pkill -f wineserver`.
- **`grep` de macOS no admite `\|` en expresiones básicas.** Hay que usar `grep -E`.
- **`find` no sigue enlaces simbólicos.** Uno de los runtimes de Wine estaba en
  `/Applications` como enlace a otra carpeta y pasaba desapercibido; hace falta
  `find -L`.
- **En bash, `«$variable»` se rompe** si la configuración regional no es UTF-8:
  los bytes de `»` se pegan al nombre. Usar `«${variable}»`.
- **Steam ignora un segundo lanzamiento** si ya hay una instancia: parece que «no
  abre» cuando en realidad enfoca la existente. El lanzador lo detecta y avisa.
- **Las trazas de OSLog a nivel `info` no salen en `log show`** sin `--info`. Por
  eso el demonio escribe además a fichero.

---

## 8. Cronología de la sesión

| Hora | Hito |
|---|---|
| 17:14 | Se confirma que AMFI mata el proceso con el entitlement |
| 17:19 | Se descarta la vía TCC/Accesibilidad |
| 17:38 | Se descubre el `dlopen` por nombre suelto de `winebus` |
| 17:46 | La shim se carga dentro de `winedevice.exe` |
| 18:12 | El mando conecta por BLE y se identifica (`el mando de pruebas`) |
| 19:01 | El inyector funciona en SDL3 y Steam reconoce el mando (pero los juegos nativos no responderán) |
| 19:41 | Se verifica la decodificación de botones con bytes crudos |
| 19:53 | La secuencia USB conmuta el mando a HID real |
| 20:05 | Steam ve el mando por USB (`type: 057e 2069`) |
| ~20:2x | **Dragonsword Awakening funciona en el Steam de Windows bajo Wine, con cable y sin él** |
