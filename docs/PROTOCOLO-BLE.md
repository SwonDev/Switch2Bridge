# Protocolo BLE del Nintendo Switch 2 Pro Controller

Referencia del protocolo tal como está implementado y **verificado contra
hardware real** en este proyecto. Si algo se rompe, esta es la fuente de verdad
sobre cómo se habla con el mando.

Base: ingeniería inversa de la comunidad (Nadeflore, ndeadly, bitaxislabs,
`trevlars/switch2-controllers-linux`), contrastada byte a byte con el mando
`el mando de pruebas`.

---

## Identificación en el anuncio BLE

Los datos de fabricante del anuncio llevan el identificador de compañía
**`0x0553`** (Nintendo). Tras esos dos bytes:

| Offset (desde el cuerpo) | Campo |
|---|---|
| 3 | `vendorID` (LE 16 bits) — `0x057E` |
| 5 | `productID` (LE 16 bits) |
| 10–16 | MAC del host emparejado; `0` = en modo emparejamiento |

Modelos:

| PID | Modelo |
|---|---|
| `0x2066` | Joy-Con 2 derecho |
| `0x2067` | Joy-Con 2 izquierdo |
| `0x2069` | **Pro Controller 2** |
| `0x2073` | Mando GameCube NSO |

---

## Características GATT

| UUID | Uso |
|---|---|
| `AB7DE9BE-89FE-49AD-828F-118F09DF7FD2` | reportes de entrada (notify) |
| `649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005` | escritura de comandos (sin respuesta) |
| `C765A961-D9D8-4D36-A20A-5315B111836A` | respuestas a comandos (notify) |
| `CC483F51-9258-427D-A939-630C31F72B05` | vibración HD (Pro y GameCube) |
| `FA19B0FB-CD1F-46A7-84A1-BBB09E00C149` | vibración Joy-Con derecho |
| `289326CB-A471-485D-A8F4-240C14F18241` | vibración Joy-Con izquierdo |

**No expone el servicio HID estándar `0x1812`.** Esa es la razón de fondo de que
macOS no lo reconozca por Bluetooth.

---

## Trama de comando

```
[ comando ][ 0x91 ][ 0x01 ][ subcomando ][ 0x00 ][ longitud ][ 0x00 ][ 0x00 ][ datos… ]
```

La respuesta llega por la característica de respuestas. Es válida si
`respuesta[0] == comando` y `respuesta[1] == 0x01`; la carga útil empieza en el
byte 8.

### Comandos usados

| Comando | Subcomando | Función |
|---|---|---|
| `0x02` | `0x04` | leer memoria (máx. `0x4F` bytes) |
| `0x09` | `0x07` | LEDs de jugador |
| `0x0A` | `0x02` | reproducir preset de vibración |
| `0x0C` | `0x02` / `0x04` | iniciar / activar funciones |
| `0x15` | `0x01`,`0x04`,`0x02`,`0x03` | emparejamiento (MAC, LTK1, LTK2, fin) |

### Lectura de memoria

Carga útil: `[longitud][0x7E][0x00][0x00][dirección LE 32 bits]`

| Dirección | Contenido |
|---|---|
| `0x00013000` | información del mando (nº de serie, VID, PID, colores) |
| `0x000130A8` | calibración de fábrica del stick izquierdo |
| `0x000130E8` | calibración de fábrica del stick derecho |
| `0x001FC042` | calibración de usuario del stick izquierdo |
| `0x001FC062` | calibración de usuario del stick derecho |

Si los tres primeros bytes de la calibración de usuario son `FF FF FF`, no hay
calibración de usuario y se usa la de fábrica.

### Patrón de LEDs de jugador

```
1→0x01  2→0x03  3→0x07  4→0x0F  5→0x09  6→0x05  7→0x0D  8→0x06
```

---

## Reporte de entrada (63 bytes)

Verificado con volcado real:

```
1a 0b 00 00 | 00 00 00 00 | 00 00 | c9 07 88 | 63 e8 82 | …
 timestamp     botones       —      stick izq  stick der
```

| Offset | Tamaño | Campo |
|---|---|---|
| 0 | 4 | marca de tiempo (LE, creciente) |
| 4 | 4 | máscara de botones (LE 32 bits) |
| 10 | 3 | stick izquierdo, dos ejes de 12 bits empaquetados |
| 13 | 3 | stick derecho, ídem |
| 0x1F | 2 | batería en milivoltios |
| 0x30 | 6 | acelerómetro X, Y, Z (int16) |
| 0x36 | 6 | giroscopio X, Y, Z (int16) |
| 0x3C | 1 | gatillo izquierdo analógico (sólo GameCube) |
| 0x3D | 1 | gatillo derecho analógico (sólo GameCube) |

### Ejes empaquetados

Tres bytes contienen dos valores de 12 bits:

```
valor = b0 | (b1 << 8) | (b2 << 16)
x = valor & 0xFFF          y = valor >> 12
```

Ejemplo real: `c9 07 88` → x = 1993, y = 2176 (centro ≈ 2048).

### Máscara de botones

| Bit | Botón | Bit | Botón |
|---|---|---|---|
| `0x00000001` | Y | `0x00002000` | Captura |
| `0x00000002` | X | `0x00004000` | C |
| `0x00000004` | B | `0x00010000` | Abajo |
| `0x00000008` | A | `0x00020000` | Arriba |
| `0x00000010` | SR derecho | `0x00040000` | Derecha |
| `0x00000020` | SL derecho | `0x00080000` | Izquierda |
| `0x00000040` | R | `0x00100000` | SR izquierdo |
| `0x00000080` | ZR | `0x00200000` | SL izquierdo |
| `0x00000100` | − | `0x00400000` | L |
| `0x00000200` | + | `0x00800000` | ZL |
| `0x00000400` | stick derecho | `0x01000000` | GR |
| `0x00000800` | stick izquierdo | `0x02000000` | GL |
| `0x00001000` | Home | | |

Comprobado en hardware: `04 00 00 00` = B, `08 00 00 00` = A,
`00 02 00 00` = +.

---

## Saludo tras conectar

Orden que funciona (el resto falla o entrega reportes vacíos):

1. Suscribirse a la característica de **respuestas** — antes de cualquier comando.
2. Leer información del mando (`0x40` bytes en `0x00013000`).
3. Leer calibración de ambos sticks (usuario, con reserva a fábrica).
4. Encender LED de jugador (`0x09`/`0x07`).
5. Activar funciones: `0x0C`/`0x02` y luego `0x0C`/`0x04`, con
   `0x03 | 0x04` (entrada básica + movimiento).
6. **Al final**, suscribirse a la característica de **entrada**.

A partir de ahí llegan reportes a ~29 Hz.

---

## Secuencia USB-C

Por cable el mando arranca en modo propietario. Enviando 17 comandos al endpoint
**bulk OUT de la interfaz 1** se conmuta a HID estándar. Están en
`daemon/Sources/USBSwitch2/usb_switch2.c`, con 50 ms entre comandos.

Tras la secuencia, macOS lo expone como gamepad HID real:

```
hidutil → 0x57e 0x2069 USB AppleUserHIDDevice "Pro Controller"
descriptor → Report ID 9: 21 botones + 4 ejes de 12 bits (X, Y, Rx, Rz)
```

---

## Emparejamiento (implementado pero no activado)

El mando recuerda **un solo host**. Los comandos `0x15` permiten grabarle la MAC
del Mac y una LTK fija para que reconecte sin pulsar SYNC.

⚠️ **Efecto secundario:** sustituye el emparejamiento con la consola, y habría
que volver a sincronizar el mando con la Switch 2 para usarlo allí. Por eso no
se ejecuta automáticamente.
