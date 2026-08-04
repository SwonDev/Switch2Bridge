# Solución de problemas

Empieza siempre por:

```bash
./verificar.sh
```

Comprueba la cadena entera eslabón por eslabón y señala dónde se rompe.

---

## El mando no conecta por Bluetooth

**Se duerme solo.** Pulsa cualquier botón. Si no vuelve, mantén **SYNC** (arriba,
junto al USB-C) hasta que parpadeen los LEDs.

**Recuerda un solo host.** Si lo has usado en la consola, hay que volver a
sincronizarlo con el Mac — y al revés. Es el comportamiento normal de cualquier
mando de Nintendo en un PC.

**Tras reinstalar.** `./instalar.sh` reinicia el demonio y eso corta la conexión.
El mando reconecta solo en 10–30 s, o pulsa un botón para acelerarlo.

Comprobación:

```bash
./estado.sh      # debe decir MANDO CONECTADO
./monitor.sh     # debe reaccionar al mover los sticks
```

Si `estado.sh` dice *permiso de Bluetooth denegado*: Ajustes del Sistema →
Privacidad y seguridad → Bluetooth → activa **Switch2Bridge**.

---

## Funciona el puente pero el juego no responde

### Sesión de Wine antigua

**Síntoma:** el juego de Windows bajo Wine no ve el mando.

**Causa:** `winedevice.exe` sigue vivo desde antes y no repite el `dlopen` de la
shim.

**Solución:**

```bash
pkill -f winedevice; pkill -f wineserver
```

Importante: **`wineserver -k` no basta.** Es el error que más tiempo cuesta.

Comprobación de que Windows lo ve:

```bash
CO=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver
"$CO/bin/wine" --bottle Steam --cx-app reg.exe query \
  'HKLM\System\CurrentControlSet\Enum\HID'
# debe aparecer VID_057E&PID_2069&XI_00
```

---

## Dejó de funcionar tras actualizar CrossOver

Las actualizaciones sustituyen los ficheros del bundle y se llevan la shim por
delante. El agente de mantenimiento la repone en su siguiente pasada (cada seis
horas y al iniciar sesión). Para no esperar:

```bash
./reparar.sh
pkill -f winedevice; pkill -f wineserver
```

## Creé una botella nueva y no ve el mando

El agente de mantenimiento le activará el bus SDL en su siguiente pasada. Para
forzarlo: `./reparar.sh` y después cierra la sesión de Wine.

---

## Los botones están cambiados

El puente aplica disposición **Xbox por posición física**: el botón de abajo
(rotulado B en Nintendo) actúa como A.

Si te salen invertidos, en Steam está activado *Usar disposición de botones de
Nintendo*. Desactívalo.

Para cambiarlo de raíz, las macros `PULSA` de `shim/shim_sdl.c`.

---

## Un stick va mal o hay deriva

La calibración se lee del propio mando al conectar. Si falla, el demonio avisa y
usa una neutra:

```bash
grep calibración ~/Library/Application\ Support/Switch2Bridge/salida.log
```

Fuerza una relectura reconectando el mando. La zona muerta está en
`Protocolo.swift` (`zonaMuerta: Double = 80`, sobre 4095).

---

## Comprobar que el mando envía de verdad

Si dudas de si el problema es el mando o el juego, mira los bytes crudos:

```bash
rm ~/Library/Application\ Support/Switch2Bridge/reportes.log
# pulsa botones
cat ~/Library/Application\ Support/Switch2Bridge/reportes.log
```

Cada línea es una pulsación real decodificada. Ejemplo:

```
19:41:24  d1 5a 00 00 04 00 00 00 …   ← 0x04 = B
19:41:29  c0 6c 00 00 08 00 00 00 …   ← 0x08 = A
```

Si aparecen líneas, el mando y el puente funcionan y el problema está en el
juego o en su configuración.

---

## Por cable no lo reconoce

```bash
hidutil list | grep -i "57e"
# esperado: 0x57e 0x2069 USB AppleUserHIDDevice Pro Controller
```

Si no sale, revisa que el demonio detectó el cable:

```bash
grep usb ~/Library/Application\ Support/Switch2Bridge/salida.log
# usb: mando conmutado a modo HID: ya debería verse como gamepad
```

Si dice *«ya está en modo HID (o lo usa otro proceso)»*, es normal: significa que
macOS ya lo tenía tomado. Desenchufa y vuelve a enchufar para forzar la
secuencia.

---

## Volver atrás del todo

```bash
./desinstalar.sh
pkill -f winedevice; pkill -f wineserver
```

Retira app, agente, lanzador, shims de todos los runtimes y datos de soporte.
`Enable SDL` se deja puesto por ser inocuo; para quitarlo:

```bash
"$CO/bin/wine" --bottle Steam --cx-app reg.exe delete \
  'HKLM\System\CurrentControlSet\Services\winebus\Parameters' /v 'Enable SDL' /f
```
