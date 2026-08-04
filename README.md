# Switch2Bridge

**Usa el Nintendo Switch 2 Pro Controller en tu Mac, inalámbrico y con ejes
analógicos, en juegos de Windows bajo Wine (CrossOver y compatibles).**

Sin desactivar SIP · sin entitlements de Apple · sin cuentas de pago · sin hardware extra.

Probado en macOS 26.5 · Apple Silicon (M5 Pro) · agosto de 2026.

> **Qué cubre y qué no.** Está confirmado en un juego real —*Dragonsword
> Awakening*, en el Steam de Windows dentro de una botella, primero por cable y
> después **sin cable**—. **Los juegos nativos de macOS no están soportados**: se
> intentó y no funciona. El motivo, con las pruebas, está en
> [Alcance](#alcance).

---

## Por qué esto no debería ser posible

El Pro Controller 2 **no habla HID por Bluetooth**: usa un servicio GATT
propietario de Nintendo. macOS nunca crea un dispositivo de entrada para él, así
que ningún juego lo ve.

La solución evidente —publicar un mando virtual para todo el sistema— está
cerrada a cal y canto. El kernel de macOS, en
[`IOHIDResourceUserClient.cpp:132`](https://github.com/apple-oss-distributions/IOHIDFamily),
exige uno de dos *entitlements* que sólo Apple concede:

| Intento | Resultado real en el equipo |
|---|---|
| `CoreHID.HIDVirtualDevice` sin entitlement | devuelve `nil` |
| Firmado ad-hoc **con** el entitlement | AMFI mata el proceso (SIGKILL 137) |
| Firmado con un certificado **Apple Development** real | SIGKILL igualmente |
| `IOHIDUserDeviceCreateWithProperties` directo | `nil` (`IOServiceOpen:0xe00002c2`) |
| Con Accesibilidad y Monitorización de entrada concedidas | sin cambios |
| Ejecutar como root | el kernel sólo comprueba entitlements, no privilegios |
| DriverKit en modo desarrollador | *"cannot be used if SIP is enabled"* |
| Que el mando exponga HID-over-GATT | su tabla GATT sólo tiene servicios propietarios |

Ese es el muro. **Este proyecto no lo derriba: lo rodea.**

En lugar de pedirle a macOS un mando virtual para todo el sistema, mete el mando
**dentro de los procesos que lo van a consumir**, que corren en espacio de
usuario y no necesitan permiso alguno.

El recorrido completo, con todas las pruebas y los callejones sin salida, está
en [`docs/INVESTIGACION.md`](docs/INVESTIGACION.md).

---

## Cómo funciona

```
              Pro Controller 2
                    │  BLE · GATT propietario de Nintendo
                    ▼
         Switch2Bridge.app  (demonio Swift 6 + CoreBluetooth)
         saludo · calibración · LEDs · reportes a 29 Hz
                    │  socket Unix · tramas de 20 bytes
                    ▼
      libSDL2-2.0.0.dylib   ← shim dentro de winedevice.exe
      (reexporta la SDL real y añade un joystick virtual)
                    │
                    ▼
      winebus → gamepad XInput en la botella de Windows
```

**El truco:** `winebus.so` hace `dlopen("libSDL2-2.0.0.dylib")` **por nombre
suelto**, y su primer `LC_RPATH` es `@loader_path/`. Poniendo ahí nuestra
biblioteca, Wine carga la nuestra en lugar de la suya; como reexporta la SDL
original, el runtime no pierde nada. Damos de alta un joystick virtual y Wine
crea un gamepad XInput real dentro de la botella.

Es legítimo y reversible: dentro del bundle ajeno sólo se **añade** un fichero,
que el desinstalador retira.

Detalle técnico en [`docs/COMO-FUNCIONA.md`](docs/COMO-FUNCIONA.md).

---

## Requisitos

| Requisito | Detalle |
|---|---|
| macOS | 15 (Sequoia) o posterior. Probado en 26.5 |
| Procesador | Apple Silicon o Intel |
| Herramientas de línea de órdenes de Xcode | para compilar el demonio: `xcode-select --install` |
| Un runtime de Wine | CrossOver, Wine oficial o cualquier empaquetado propio |
| El mando | Nintendo Switch 2 Pro Controller |

No hace falta cuenta de desarrollador de Apple, ni desactivar SIP, ni permisos
especiales más allá del de Bluetooth que macOS pide la primera vez.

---

## Instalación

**1. Descarga el proyecto.**

```bash
git clone https://github.com/SwonDev/Switch2Bridge.git
cd Switch2Bridge
```

**2. Ejecuta el instalador.**

```bash
./instalar.sh
```

Compila el demonio, lo instala como agente de arranque y coloca la shim de SDL
en cada runtime de Wine que encuentre. Tarda menos de un minuto.

**3. Concede el permiso de Bluetooth.** macOS lo pedirá la primera vez que el
demonio arranque. Si no aparece el aviso, ve a *Ajustes del Sistema → Privacidad
y seguridad → Bluetooth* y activa **Switch2Bridge**.

**4. Enciende el mando.** Si venía de la consola, mantén pulsado **SYNC** —el
botón pequeño de arriba, junto al USB-C— hasta que los LEDs parpadeen. El mando
recuerda un solo host, así que tendrás que volver a sincronizarlo con la Switch
cuando quieras usarlo allí.

**5. Comprueba que todo está en su sitio.**

```bash
./verificar.sh
```

Recorre la cadena entera y debe terminar con `La cadena está intacta`. Si algo
falla, te dice qué eslabón y con qué orden se arregla.

**6. Cierra la sesión de Wine** para que cargue la shim recién instalada:

```bash
pkill -f winedevice; pkill -f wineserver
```

Esto sólo hace falta la primera vez y después de cada reinstalación.

### Qué deja instalado

| Qué | Dónde |
|---|---|
| Demonio sin interfaz (`LSUIElement`) | `~/Applications/Switch2Bridge.app` |
| Agente del demonio | `~/Library/LaunchAgents/dev.swondev.switch2bridge.plist` |
| Agente de mantenimiento | `~/Library/LaunchAgents/dev.swondev.switch2bridge.reparar.plist` |
| Copia de la SDL original y registros | `~/Library/Application Support/Switch2Bridge/` |
| Shim de SDL | dentro de cada runtime de Wine detectado |
| `Enable SDL = 1` | en el registro de cada botella |

El instalador es **idempotente**: puedes volver a ejecutarlo cuantas veces
quieras.

### Se mantiene solo

No hace falta reinstalar cuando cambian las cosas. Un agente de mantenimiento se
ejecuta al iniciar sesión y cada seis horas, y se encarga de:

- **Reponer la shim** en los runtimes donde falte. Las actualizaciones de
  CrossOver sobrescriben su bundle y se la llevan por delante; el agente la
  vuelve a poner sin que te enteres.
- **Activar el bus SDL en botellas nuevas**, incluidas las que crees después de
  instalar.

Detecta las botellas por su `system.reg`, así que cubre CrossOver, Whisky,
Mythic, Wineskin, Heroic y cualquier prefijo suelto, estén donde estén.

Puedes forzar una revisión en cualquier momento:

```bash
./reparar.sh
```

Lo único que sigue siendo manual es cerrar la sesión de Wine para que cargue una
shim recién repuesta: `pkill -f winedevice; pkill -f wineserver`.

Dentro de los bundles ajenos no se sobrescribe nada: sólo se **añade** un
fichero, que el desinstalador retira.

---

## Uso

### Juegos de Windows bajo Wine — ruta confirmada

Ésta es la que está probada de principio a fin en un juego real.

1. Mando encendido y conectado (`./estado.sh` debe decir *MANDO CONECTADO*).
2. Cierra la sesión de Wine:
   ```bash
   pkill -f winedevice; pkill -f wineserver
   ```
   Importante: `wineserver -k` **no basta** — es el error que más tiempo cuesta.
3. Abre tu botella con el Steam de Windows dentro. El mando aparece como
   `HID\VID_057E&PID_2069&XI_00`, un gamepad XInput con identidad Nintendo.
4. En ese Steam, **configura el mando una vez**: detéctalo como mando de Switch
   Pro, mapea los controles en las opciones de mando y guarda.
5. A jugar.

> Así se validó: *Dragonsword Awakening* respondió perfectamente, primero con el
> cable puesto y después desenchufado, sólo por Bluetooth.

### Por cable USB-C

Enchúfalo y ya está: el demonio detecta el cable y envía la secuencia que
conmuta el mando a **modo HID estándar**. macOS lo expone entonces como gamepad
real (`AppleUserHIDDevice`, usage 1/5 = Game Pad, 4 ejes, 21 botones), lo que
también sirve para Wine sin necesidad del Bluetooth.

Importante: Que macOS lo exponga **no** significa que los juegos nativos lo usen bien:
ver [Alcance](#alcance).

---

## Disposición de botones

Mapeo **Xbox por posición física**, aplicado en el puente:

| Pulsas (rótulo Nintendo) | El juego recibe |
|---|---|
| **B** (abajo) | **A** |
| **A** (derecha) | **B** |
| **Y** (izquierda) | **X** |
| **X** (arriba) | **Y** |
| − / + | Back / Start |
| L / R | LB / RB |
| ZL / ZR | Gatillos |
| Captura · GR · GL · C | misc1 · paddle1 · paddle2 · paddle3 |

El botón de abajo salta, como en cualquier mando de Xbox. Si en Steam activas
*Usar disposición de botones de Nintendo* lo volvería a invertir: déjalo
desactivado.

---

## Diagnóstico

```bash
./verificar.sh   # comprobación completa de la cadena
./estado.sh      # resumen rápido
./monitor.sh     # sticks, gatillos y botones en tiempo real
```

Registros en `~/Library/Application Support/Switch2Bridge/`:

| Fichero | Qué contiene |
|---|---|
| `salida.log` | demonio: conexión BLE, saludo, USB |
| `shim.log` | shim de SDL dentro de Wine |
| `reportes.log` | bytes crudos del mando al pulsar botones |
| `gatt.log` | tabla GATT completa del mando |

Problemas frecuentes en [`docs/SOLUCION-PROBLEMAS.md`](docs/SOLUCION-PROBLEMAS.md).

Si vas a seguir desarrollándolo, empieza por
[`docs/CONTINUIDAD.md`](docs/CONTINUIDAD.md): estado, trampas conocidas e ideas
pendientes.

---

## Alcance

| Escenario | Bluetooth | USB-C |
|---|---|---|
| Juegos de **Windows bajo Wine** (CrossOver y otros runtimes) | Sí, confirmado | Sí |
| Juegos **nativos de macOS** | No | No |

### Por qué los juegos nativos no funcionan

Se intentó y **no salió**. Merece la pena dejarlo escrito para que nadie repita
el camino:

- Por cable, macOS **sí** publica el mando como gamepad HID real (verificado:
  `AppleUserHIDDevice`, 21 botones, 4 ejes, eventos reales). Pero los motores lo
  mapean **mal y con errores**, porque su descriptor es atípico: los ejes del
  stick derecho son `Rx`/`Rz` en vez de los habituales, no hay *hat* y expone 21
  botones sin correspondencia estándar.
- Motores como Unity leen por `IOHIDManager` y `GameController.framework`, y
  sólo ascienden a `Gamepad` los mandos de su base de datos interna. Uno
  desconocido queda como joystick genérico.
- `GameController.framework` no lo adopta en absoluto: sólo expone los mandos de
  la lista blanca de Apple (comprobado: `GCController.controllers()` devuelve
  vacío con el mando conectado por cable).
- Se probó a inyectar un joystick virtual en el Steam de macOS vía SDL3. Steam
  llegaba a reconocerlo, pero **en los juegos no funcionó**, así que esa vía se
  retiró del proyecto en lugar de dejarla como falsa promesa.

La solución de fondo sería publicar un HID virtual para todo el sistema, y eso
exige el entitlement que Apple no concede a cuentas gratuitas. Con hardware que
se presentase como un mando ya conocido (por ejemplo un Xbox 360) sí se
resolvería, pero eso queda fuera de este proyecto.

---

## Desinstalación

```bash
./desinstalar.sh
```

Retira la app, el agente, el lanzador, las shims de todos los runtimes de Wine y
los datos de soporte. Nada queda tocado en CrossOver ni en Steam.

---

## Estructura

```
daemon/Sources/Switch2Bridge/   demonio Swift 6
  Protocolo.swift               UUIDs, comandos, reportes, calibración
  SesionMando.swift             sesión BLE y saludo del protocolo
  ServidorEstado.swift          servidor de sockets Unix
  VigilanteUSB.swift            detección y conmutación por USB-C
  Rutas.swift                   rutas compartidas y traza
daemon/Sources/USBSwitch2/      secuencia de inicialización USB (IOKit, en C)
shim/shim_sdl.c                 shim de SDL que carga Wine

docs/COMO-FUNCIONA.md           arquitectura y decisiones de diseño
docs/INVESTIGACION.md           todas las pruebas y los callejones sin salida
docs/PROTOCOLO-BLE.md           el protocolo del mando, documentado
docs/SOLUCION-PROBLEMAS.md      síntoma, causa y solución
docs/CONTINUIDAD.md             estado, ideas pendientes y cómo retomarlo
instalar.sh                     instalación completa
reparar.sh                      mantenimiento automático de la integración
verificar.sh                    comprobación de la cadena, eslabón por eslabón
estado.sh · monitor.sh          diagnóstico rápido y visor en vivo
desinstalar.sh                  reversión total
```

---

## Créditos

Protocolo BLE documentado por la comunidad: **Nadeflore**, **ndeadly**,
**bitaxislabs** y el puente de Linux
[`trevlars/switch2-controllers-linux`](https://github.com/trevlars/switch2-controllers-linux).
Secuencia USB de **ikz87** (`NSW2-controller-enabler`) y
[`dannydarvish/Switch2ProMac`](https://github.com/dannydarvish/Switch2ProMac).

Las dos técnicas de integración (la shim por `@loader_path` en Wine y la
inyección en el Steam interno de macOS) son aportación de este proyecto.

Proyecto no oficial. Sin relación con Nintendo, CodeWeavers ni Valve.
Licencia MIT.
