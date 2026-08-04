# Continuidad del proyecto

Documento para retomar el desarrollo sin tener que reconstruir el contexto.
Si vuelves a este proyecto después de meses —o si lo retoma otra persona—
empieza por aquí.

---

## Estado actual

| | |
|---|---|
| Versión | 1.0 |
| Estado | funcional y en uso |
| Confirmado en | juegos de Windows bajo Wine, con cable y sin cable |
| No soportado | juegos nativos de macOS (intentado; ver más abajo) |
| Plataforma de prueba | macOS 26.5, Apple Silicon, CrossOver 25 |

La validación de referencia: *Dragonsword Awakening*, ejecutado en el Steam de
Windows dentro de una botella de Wine. Se detectó el mando en ese Steam como
mando de Switch Pro, se mapearon los controles en sus opciones, y el juego
respondió correctamente primero con el cable puesto y después sólo por
Bluetooth.

---

## Lo que hay que saber antes de tocar nada

Estas cinco cosas son las que cuestan horas si se desconocen.

**1. macOS no permite publicar un mando virtual para todo el sistema.**
El kernel exige entitlements que Apple sólo concede a cuentas de pago, y AMFI
mata el proceso aunque se firme con un certificado de desarrollo real. Root no
sirve: la comprobación es puramente de entitlements. No merece la pena volver a
intentarlo salvo que se disponga del entitlement. Pruebas completas en
[`INVESTIGACION.md`](INVESTIGACION.md).

**2. `wineserver -k` NO mata la sesión de Wine.**
`winedevice.exe` sigue vivo con los mismos PID y nunca repite el `dlopen` de la
shim, así que los cambios parecen no aplicarse. Siempre:

```bash
pkill -f winedevice; pkill -f wineserver
```

**3. El bus SDL de Wine viene desactivado en macOS.**
Sin `Enable SDL = 1` en
`HKLM\System\CurrentControlSet\Services\winebus\Parameters` de la botella, la
shim se carga pero no ocurre nada. El instalador lo escribe directamente en
`system.reg`.

**4. La shim gana por `@loader_path`, no por otras vías.**
`DYLD_LIBRARY_PATH` no vale (el cargador de Wine tiene *hardened runtime* y las
variables DYLD se eliminan) y `~/lib` tampoco (los `LC_RPATH` del llamante ganan
a las rutas de reserva de dyld). El único sitio que funciona es el propio
directorio de `winebus.so`.

**5. Reinstalar corta la conexión Bluetooth.**
`instalar.sh` reinicia el demonio. El mando reconecta solo en 10–30 segundos, o
antes si pulsas un botón. No es un fallo.

---

## Cómo retomar el desarrollo

```bash
cd Switch2Bridge

# Compilar sólo el demonio, sin instalar
cd daemon && swift build -c release && cd ..

# Ciclo completo: compilar, instalar y verificar
./instalar.sh && ./verificar.sh

# Ver el mando en vivo mientras se depura
./monitor.sh
```

Registros útiles en `~/Library/Application Support/Switch2Bridge/`:

| Fichero | Para qué |
|---|---|
| `salida.log` | conexión BLE, saludo del protocolo, detección USB |
| `shim.log` | si la shim entró en `winedevice.exe` y dio de alta el joystick |
| `reportes.log` | bytes crudos del mando al pulsar botones |
| `gatt.log` | tabla GATT completa del mando |

Para verificar que Windows ve el mando dentro de una botella:

```bash
CO=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver
"$CO/bin/wine" --bottle NOMBRE --cx-app reg.exe query \
  'HKLM\System\CurrentControlSet\Enum\HID'
# debe aparecer VID_057E&PID_2069&XI_00
```

---

## Qué se intentó y no salió

No repetir estos caminos sin un motivo nuevo.

| Intento | Resultado |
|---|---|
| HID virtual del sistema (CoreHID / IOHIDUserDevice) | bloqueado por entitlement; AMFI mata el proceso |
| Ejecutar como root o LaunchDaemon | el kernel sólo comprueba entitlements |
| DriverKit en modo desarrollador | exige desactivar SIP |
| Que el mando exponga HID-over-GATT | su tabla GATT no tiene el servicio 0x1812 |
| Inyectar un joystick SDL en el Steam de macOS | Steam lo reconoce, pero los juegos nativos no responden |
| Confiar en el HID real por cable para juegos nativos | los motores lo mapean mal: descriptor atípico |

El código del inyector para Steam se retiró del proyecto al comprobarse que no
funcionaba. Si alguien quiere retomarlo, el planteamiento está descrito en
[`INVESTIGACION.md`](INVESTIGACION.md), sección 4.

---

## Ideas pendientes

Ordenadas por relación entre valor y esfuerzo.

**Emparejamiento persistente (implementado a medias).**
Los comandos `0x15` permiten grabar en el mando la MAC del Mac y una LTK fija
para que reconecte sin pulsar SYNC. Está documentado en
[`PROTOCOLO-BLE.md`](PROTOCOLO-BLE.md) pero no se activa, porque sustituiría el
emparejamiento con la consola. Convendría exponerlo como una orden explícita del
tipo `./emparejar.sh`, avisando del efecto secundario.

**Vibración HD.**
El mando tiene actuadores reales y la característica de vibración está
identificada (`CC483F51-…`). Faltaría el canal de vuelta: SDL entrega la orden
de vibración al joystick virtual mediante las funciones de `rumble` del
descriptor, y habría que reenviarla por el socket hasta el demonio.

**Giroscopio.**
El reporte ya trae acelerómetro y giroscopio decodificados (offsets `0x30` y
`0x36`), pero no se publican por el socket. Un servidor DSU/cemuhook los
expondría a los emuladores.

**Gatillos analógicos.**
El Pro Controller 2 los envía como digitales; el mando de GameCube NSO sí tiene
analógicos y el código ya los contempla. Sin verificar por falta de ese mando.

**Juegos nativos de macOS.**
La única vía realista es hardware que se presente como un mando ya conocido —por
ejemplo un ESP32-S3 que hable BLE con el mando y se ofrezca al Mac como un
gamepad USB estándar—. El protocolo BLE necesario ya está descifrado y
funcionando en este proyecto, así que el trabajo sería el firmware.

**Reconexión tras suspender el Mac.**
Sin verificar. Conviene probar si el demonio recupera la conexión al despertar o
si conviene forzar un rescaneo.

---

## Decisiones de diseño y su motivo

| Decisión | Motivo |
|---|---|
| Un demonio y un socket, en vez de integrarlo todo | permite añadir consumidores nuevos sin tocar el núcleo |
| Reexportar la SDL original en vez de sustituirla | el runtime conserva toda su funcionalidad |
| Sondear el tamaño del descriptor de SDL3 | una constante fija envejecería con cada versión de SDL |
| Escribir `Enable SDL` directo en `system.reg` | no exige arrancar una sesión de Wine y vale para cualquier runtime |
| Traza a fichero además de OSLog | las trazas `info` de OSLog no salen en `log show` sin `--info` |
| Latido de estado cada segundo | evita que las herramientas se queden bloqueadas esperando datos |
| Volcado sólo al cambiar botones | el ruido de los sticks llenaría el registro en un segundo |
| Mapeo Xbox por posición física | es lo que esperan los juegos, y Steam puede invertirlo si se prefiere |

---

## Créditos y límites

El protocolo BLE es trabajo de la comunidad (Nadeflore, ndeadly, bitaxislabs y
el puente de Linux `trevlars/switch2-controllers-linux`); la secuencia USB, de
ikz87 y `dannydarvish/Switch2ProMac`. La aportación propia de este proyecto es
la técnica de integración con Wine mediante `@loader_path`, y el demonio en
Swift que la alimenta.

Proyecto no oficial, sin relación con Nintendo, CodeWeavers ni Valve.
