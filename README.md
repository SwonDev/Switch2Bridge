# Switch2Bridge

**Usa el Nintendo Switch 2 Pro Controller en tu Mac, inalámbrico y con ejes
analógicos, en juegos de Windows bajo Wine.**

Sin desactivar SIP · sin entitlements de Apple · sin cuentas de pago · sin hardware extra.

Probado en macOS 26.5 · Apple Silicon (M5 Pro) · agosto de 2026.

> **Estado de las pruebas.** La ruta de Wine está **confirmada en un juego real**:
> *Dragonsword Awakening*, en el Steam de Windows dentro de una botella, primero
> por cable y después **sin cable**. La ruta para juegos nativos de macOS está
> implementada y se comprueba que Steam reconoce el mando, pero **aún no se ha
> confirmado en un juego nativo concreto**. Ver [Alcance](#alcance).

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
                    ├──────────────────────────┐
                    ▼                          ▼
      libSDL2-2.0.0.dylib              inyector.dylib
      dentro de winedevice.exe         dentro de steam_osx
      (reexporta la SDL real)          (SDL2 o SDL3, se adapta)
                    │                          │
                    ▼                          ▼
      winebus → HID XInput            Steam ve el mando
      en la botella de Windows        → Steam Input → juego nativo
```

Dos trucos, ambos legítimos y reversibles:

**1. Wine.** `winebus.so` hace `dlopen("libSDL2-2.0.0.dylib")` **por nombre
suelto**, y su primer `LC_RPATH` es `@loader_path/`. Poniendo ahí nuestra
biblioteca, Wine carga la nuestra; como reexporta la SDL original, no pierde
nada. Damos de alta un joystick virtual y Wine crea un gamepad XInput real
dentro de la botella.

**2. Steam para macOS.** El `steam_osx` que de verdad se ejecuta —el de
`Application Support`, no el de `/Applications`— **no tiene hardened runtime**,
así que admite `DYLD_INSERT_LIBRARIES`. Inyectamos un joystick virtual en su
SDL3 y Steam lo reconoce como mando real. A partir de ahí **Steam Input** se lo
entrega a los juegos, incluso a los de Unity que no reconocerían el mando por su
cuenta.

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
| Lanzador de Steam con el mando | `~/Applications/Steam con mando.app` |
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

### Juegos nativos de macOS — implementado, pendiente de confirmar

1. Enciende el mando.
2. Abre **«Steam con mando»** desde `~/Applications` (no el Steam normal).
   Si ya tenías Steam abierto, te pregunta y lo reinicia solo.
3. **Una vez por juego:** clic derecho → *Propiedades → Mando* → **Activar
   Steam Input**.

> Se ha comprobado que Steam reconoce el mando inyectado
> (`Controller 0 attributes: ProductID: 8297`), pero **no se ha confirmado
> todavía en un juego nativo concreto**. Si lo pruebas, cuéntalo en un *issue*.
>
> El paso 3 no es opcional: motores como Unity sólo convierten en `Gamepad` los
> mandos de su base de datos interna y a los desconocidos los ignoran, aunque
> sean HID reales.

### Por cable USB-C (todos los juegos, sin configurar nada)

Enchúfalo y ya está. El demonio detecta el cable y envía la secuencia que
conmuta el mando a **modo HID estándar**; macOS lo expone entonces como gamepad
real (`AppleUserHIDDevice`, usage 1/5 = Game Pad, 4 ejes, 21 botones).

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
| `inyector.log` | inyector dentro de Steam y juegos |
| `reportes.log` | bytes crudos del mando al pulsar botones |
| `gatt.log` | tabla GATT completa del mando |

📖 Problemas frecuentes en
[`docs/SOLUCION-PROBLEMAS.md`](docs/SOLUCION-PROBLEMAS.md).

---

## Alcance

| Escenario | Bluetooth | USB-C | Estado |
|---|---|---|---|
| Juegos de Windows bajo Wine (CrossOver y otros runtimes) | ✅ | ✅ | **confirmado en juego real** |
| Juegos nativos de macOS vía Steam Input | ✅ | ✅ | implementado; Steam reconoce el mando, falta confirmar en juego |
| Juegos nativos fuera de Steam que sólo usen `GCController` | ❌ | ❌ | no alcanzable |

La última fila es el límite duro: `GameController.framework` sólo expone los
mandos de la lista blanca de Apple, y publicar un HID virtual para todo el
sistema exige el entitlement que Apple no concede a cuentas gratuitas. Para ese
caso haría falta hardware que se presentase como un mando ya conocido.

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
shim/inyector.c                 inyector SDL2/SDL3 para Steam y juegos
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
