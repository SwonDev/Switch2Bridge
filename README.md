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

📖 El recorrido completo, con todas las pruebas y los callejones sin salida, está
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

📖 Detalle técnico en [`docs/COMO-FUNCIONA.md`](docs/COMO-FUNCIONA.md).

---

## Instalación

```bash
cd ~/Switch2Bridge
./instalar.sh
```

Deja instalado:

| Qué | Dónde |
|---|---|
| Demonio sin interfaz (`LSUIElement`) | `~/Applications/Switch2Bridge.app` |
| Arranque automático al iniciar sesión | `~/Library/LaunchAgents/dev.swondev.switch2bridge.plist` |
| Shim de SDL | dentro de cada runtime de Wine detectado |
| `Enable SDL = 1` | en el registro de cada botella |

Es **idempotente**. Vuelve a ejecutarlo tras actualizar CrossOver o Steam,
porque la actualización se lleva por delante la shim.

Después:

```bash
./verificar.sh    # comprueba la cadena entera, eslabón por eslabón
```

---

## Uso

### Juegos de Windows bajo Wine — ruta confirmada

Ésta es la que está probada de principio a fin en un juego real.

1. Mando encendido y conectado (`./estado.sh` debe decir *MANDO CONECTADO*).
2. Cierra la sesión de Wine:
   ```bash
   pkill -f winedevice; pkill -f wineserver
   ```
   ⚠️ `wineserver -k` **no basta** — es el error que más tiempo cuesta.
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

⚠️ Que macOS lo exponga **no** significa que los juegos nativos lo usen bien:
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

📖 Problemas frecuentes en
[`docs/SOLUCION-PROBLEMAS.md`](docs/SOLUCION-PROBLEMAS.md).

---

## Alcance

| Escenario | Bluetooth | USB-C |
|---|---|---|
| Juegos de **Windows bajo Wine** (CrossOver y otros runtimes) | ✅ confirmado | ✅ |
| Juegos **nativos de macOS** | ❌ | ❌ |

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

docs/                           investigación, arquitectura, protocolo, problemas
instalar.sh · desinstalar.sh · verificar.sh · estado.sh · monitor.sh
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
