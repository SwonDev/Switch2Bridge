// shim_sdl.c — puente entre el demonio BLE y el bus SDL de Wine.
//
// Esta biblioteca se instala como «libSDL2-2.0.0.dylib» dentro de
// CrossOver/lib/wine/x86_64-unix/, que es el primer LC_RPATH de winebus.so.
// Cuando winebus hace dlopen("libSDL2-2.0.0.dylib") carga ésta en lugar de la
// de CrossOver. Reexportamos la SDL real (una copia nuestra, fuera del bundle)
// para que Wine siga teniendo la API completa, y además damos de alta un
// joystick virtual alimentado por el socket del demonio.
//
// Resultado: Wine crea un gamepad HID de Windows con ejes analógicos reales,
// visible para Steam y para los juegos de la botella.

#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <time.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Trozo mínimo de la API de SDL2 que necesitamos (evita depender de cabeceras)
// ---------------------------------------------------------------------------

typedef struct SDL_Joystick SDL_Joystick;
typedef struct { uint8_t data[16]; } SDL_JoystickGUID;

#define SDL_INIT_JOYSTICK           0x00000200u
#define SDL_JOYSTICK_TYPE_GAMECONTROLLER 1

extern uint32_t SDL_WasInit(uint32_t flags);
extern int  SDL_JoystickAttachVirtual(int type, int naxes, int nbuttons, int nhats);

// Descriptor extendido (SDL ≥ 2.24). Nos permite fijar fabricante, producto y
// nombre para que Steam muestre los glifos de Nintendo en lugar de un mando
// genérico. Si la SDL de turno no lo soporta, caemos al alta simple.
#define SDL_VIRTUAL_JOYSTICK_DESC_VERSION 1
typedef struct {
    uint16_t version;
    uint16_t type;
    uint16_t naxes;
    uint16_t nbuttons;
    uint16_t nhats;
    uint16_t vendor_id;
    uint16_t product_id;
    uint16_t padding;
    uint32_t button_mask;
    uint32_t axis_mask;
    const char *name;
    void *userdata;
    void (*Update)(void *userdata);
    void (*SetPlayerIndex)(void *userdata, int player_index);
    int  (*Rumble)(void *userdata, uint16_t low_frequency_rumble, uint16_t high_frequency_rumble);
    int  (*RumbleTriggers)(void *userdata, uint16_t left_rumble, uint16_t right_rumble);
    int  (*SetLED)(void *userdata, uint8_t red, uint8_t green, uint8_t blue);
    int  (*SendEffect)(void *userdata, const void *data, int size);
} SDL_VirtualJoystickDesc;

extern int SDL_JoystickAttachVirtualEx(const SDL_VirtualJoystickDesc *desc);
extern SDL_Joystick *SDL_JoystickOpen(int device_index);
extern int  SDL_JoystickSetVirtualAxis(SDL_Joystick *joystick, int axis, int16_t value);
extern int  SDL_JoystickSetVirtualButton(SDL_Joystick *joystick, int button, uint8_t value);
extern SDL_JoystickGUID SDL_JoystickGetGUID(SDL_Joystick *joystick);
extern void SDL_JoystickGetGUIDString(SDL_JoystickGUID guid, char *pszGUID, int cbGUID);
extern int  SDL_GameControllerAddMapping(const char *mappingString);
extern const char *SDL_GetError(void);

// ---------------------------------------------------------------------------
// Protocolo del socket (debe coincidir con EstadoMando.trama() en Swift)
// ---------------------------------------------------------------------------

#define MAGIA_TRAMA 0x53325031u  // "S2P1"
#define TAMANO_TRAMA 20

// Máscara de botones del mando de Switch 2.
#define BTN_Y            0x00000001u
#define BTN_X            0x00000002u
#define BTN_B            0x00000004u
#define BTN_A            0x00000008u
#define BTN_R            0x00000040u
#define BTN_ZR           0x00000080u
#define BTN_MENOS        0x00000100u
#define BTN_MAS          0x00000200u
#define BTN_STICK_DER    0x00000400u
#define BTN_STICK_IZQ    0x00000800u
#define BTN_HOME         0x00001000u
#define BTN_CAPTURA      0x00002000u
#define BTN_C            0x00004000u
#define BTN_ABAJO        0x00010000u
#define BTN_ARRIBA       0x00020000u
#define BTN_DERECHA      0x00040000u
#define BTN_IZQUIERDA    0x00080000u
#define BTN_L            0x00400000u
#define BTN_ZL           0x00800000u
#define BTN_GR           0x01000000u
#define BTN_GL           0x02000000u

#define NUM_EJES     6
#define NUM_BOTONES 19

// Índices de botón según el orden estándar de SDL_GameControllerButton.
enum {
    SDL_BTN_A = 0, SDL_BTN_B, SDL_BTN_X, SDL_BTN_Y,
    SDL_BTN_BACK, SDL_BTN_GUIDE, SDL_BTN_START,
    SDL_BTN_LEFTSTICK, SDL_BTN_RIGHTSTICK,
    SDL_BTN_LEFTSHOULDER, SDL_BTN_RIGHTSHOULDER,
    SDL_BTN_DPAD_UP, SDL_BTN_DPAD_DOWN, SDL_BTN_DPAD_LEFT, SDL_BTN_DPAD_RIGHT,
    SDL_BTN_MISC1, SDL_BTN_PADDLE1, SDL_BTN_PADDLE2, SDL_BTN_PADDLE3
};

static const char *MAPEO_SUFIJO =
    ",Switch 2 Pro Controller,"
    "a:b0,b:b1,x:b2,y:b3,"
    "back:b4,guide:b5,start:b6,"
    "leftstick:b7,rightstick:b8,"
    "leftshoulder:b9,rightshoulder:b10,"
    "dpup:b11,dpdown:b12,dpleft:b13,dpright:b14,"
    "misc1:b15,paddle1:b16,paddle2:b17,paddle3:b18,"
    "leftx:a0,lefty:a1,rightx:a2,righty:a3,"
    "lefttrigger:a4,righttrigger:a5,"
    "platform:Mac OS X,";

/// Registra en un fichero propio: el stderr de Wine no es accesible con fiabilidad.
static void registrar(const char *formato, ...) {
    const char *hogar = getenv("HOME");
    if (!hogar) return;

    char ruta[512];
    snprintf(ruta, sizeof(ruta), "%s/Library/Application Support/Switch2Bridge/shim.log", hogar);
    FILE *f = fopen(ruta, "a");
    if (!f) return;

    time_t ahora = time(NULL);
    char marca[32];
    strftime(marca, sizeof(marca), "%H:%M:%S", localtime(&ahora));
    fprintf(f, "[%s pid=%d] ", marca, getpid());

    va_list args;
    va_start(args, formato);
    vfprintf(f, formato, args);
    va_end(args);

    fprintf(f, "\n");
    fclose(f);
}

static void ruta_socket(char *destino, size_t tam) {
    const char *hogar = getenv("HOME");
    if (!hogar) hogar = "/tmp";
    snprintf(destino, tam, "%s/Library/Application Support/Switch2Bridge/estado.sock", hogar);
}

static int conectar_demonio(void) {
    char ruta[512];
    ruta_socket(ruta, sizeof(ruta));

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un dir;
    memset(&dir, 0, sizeof(dir));
    dir.sun_family = AF_UNIX;
    strncpy(dir.sun_path, ruta, sizeof(dir.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&dir, sizeof(dir)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/// Lee exactamente `n` bytes o devuelve 0 si la conexión se pierde.
static int leer_completo(int fd, void *bufer, size_t n) {
    uint8_t *p = bufer;
    size_t restantes = n;
    while (restantes > 0) {
        ssize_t leidos = read(fd, p, restantes);
        if (leidos > 0) {
            p += leidos;
            restantes -= (size_t)leidos;
        } else if (leidos < 0 && errno == EINTR) {
            continue;
        } else {
            return 0;
        }
    }
    return 1;
}

static int16_t leer_i16(const uint8_t *p) {
    return (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t leer_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/// Convierte un gatillo 0..255 al rango de eje de SDL (0..32767).
static int16_t gatillo_a_eje(uint8_t valor) {
    return (int16_t)((int)valor * 32767 / 255);
}

static void aplicar_estado(SDL_Joystick *joystick, const uint8_t *trama) {
    uint32_t botones = leer_u32(trama + 4);

    SDL_JoystickSetVirtualAxis(joystick, 0, leer_i16(trama + 8));
    SDL_JoystickSetVirtualAxis(joystick, 1, leer_i16(trama + 10));
    SDL_JoystickSetVirtualAxis(joystick, 2, leer_i16(trama + 12));
    SDL_JoystickSetVirtualAxis(joystick, 3, leer_i16(trama + 14));
    SDL_JoystickSetVirtualAxis(joystick, 4, gatillo_a_eje(trama[16]));
    SDL_JoystickSetVirtualAxis(joystick, 5, gatillo_a_eje(trama[17]));

    // La disposición de Nintendo está girada respecto a la de SDL/Xbox:
    // mapeamos por POSICIÓN FÍSICA, que es lo que esperan los juegos.
    #define PULSA(indice, mascara) \
        SDL_JoystickSetVirtualButton(joystick, indice, (botones & (mascara)) ? 1 : 0)

    PULSA(SDL_BTN_A, BTN_B);            // botón inferior
    PULSA(SDL_BTN_B, BTN_A);            // botón derecho
    PULSA(SDL_BTN_X, BTN_Y);            // botón izquierdo
    PULSA(SDL_BTN_Y, BTN_X);            // botón superior
    PULSA(SDL_BTN_BACK, BTN_MENOS);
    PULSA(SDL_BTN_GUIDE, BTN_HOME);
    PULSA(SDL_BTN_START, BTN_MAS);
    PULSA(SDL_BTN_LEFTSTICK, BTN_STICK_IZQ);
    PULSA(SDL_BTN_RIGHTSTICK, BTN_STICK_DER);
    PULSA(SDL_BTN_LEFTSHOULDER, BTN_L);
    PULSA(SDL_BTN_RIGHTSHOULDER, BTN_R);
    PULSA(SDL_BTN_DPAD_UP, BTN_ARRIBA);
    PULSA(SDL_BTN_DPAD_DOWN, BTN_ABAJO);
    PULSA(SDL_BTN_DPAD_LEFT, BTN_IZQUIERDA);
    PULSA(SDL_BTN_DPAD_RIGHT, BTN_DERECHA);
    PULSA(SDL_BTN_MISC1, BTN_CAPTURA);
    PULSA(SDL_BTN_PADDLE1, BTN_GR);
    PULSA(SDL_BTN_PADDLE2, BTN_GL);
    PULSA(SDL_BTN_PADDLE3, BTN_C);

    #undef PULSA
}

/// Da de alta el joystick virtual y le publica un mapeo de gamepad completo.
static SDL_Joystick *crear_joystick_virtual(void) {
    // Preferimos el alta extendida para dar identidad Nintendo al mando.
    SDL_VirtualJoystickDesc desc;
    memset(&desc, 0, sizeof(desc));
    desc.version    = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type       = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes      = NUM_EJES;
    desc.nbuttons   = NUM_BOTONES;
    desc.nhats      = 0;
    desc.vendor_id  = 0x057E;  // Nintendo
    desc.product_id = 0x2069;  // Pro Controller 2
    desc.button_mask = (NUM_BOTONES >= 32) ? 0xFFFFFFFFu : ((1u << NUM_BOTONES) - 1u);
    desc.axis_mask   = (1u << NUM_EJES) - 1u;
    desc.name       = "Nintendo Switch 2 Pro Controller";

    int indice = SDL_JoystickAttachVirtualEx(&desc);
    if (indice < 0) {
        registrar("alta extendida no disponible (%s); usando la simple", SDL_GetError());
        indice = SDL_JoystickAttachVirtual(SDL_JOYSTICK_TYPE_GAMECONTROLLER,
                                           NUM_EJES, NUM_BOTONES, 0);
    }
    if (indice < 0) {
        registrar("SDL_JoystickAttachVirtual falló: %s", SDL_GetError());
        return NULL;
    }

    SDL_Joystick *joystick = SDL_JoystickOpen(indice);
    if (!joystick) {
        registrar("SDL_JoystickOpen falló: %s", SDL_GetError());
        return NULL;
    }

    // Sin un mapeo explícito, Wine lo trataría como joystick genérico en vez de
    // como gamepad, y perderíamos la equivalencia con XInput.
    char guid[33];
    memset(guid, 0, sizeof(guid));
    SDL_JoystickGetGUIDString(SDL_JoystickGetGUID(joystick), guid, (int)sizeof(guid));

    char mapeo[1024];
    snprintf(mapeo, sizeof(mapeo), "%s%s", guid, MAPEO_SUFIJO);
    if (SDL_GameControllerAddMapping(mapeo) < 0) {
        registrar("SDL_GameControllerAddMapping falló: %s", SDL_GetError());
    }

    registrar("joystick virtual dado de alta (índice %d, guid %s)", indice, guid);
    return joystick;
}

static void *hilo_puente(void *sinUsar) {
    (void)sinUsar;

    // Espera a que Wine inicialice el subsistema de joysticks de SDL.
    for (int intento = 0; intento < 600; intento++) {
        if (SDL_WasInit(SDL_INIT_JOYSTICK) & SDL_INIT_JOYSTICK) break;
        usleep(100 * 1000);
    }
    if (!(SDL_WasInit(SDL_INIT_JOYSTICK) & SDL_INIT_JOYSTICK)) {
        registrar("SDL nunca inicializó los joysticks; el puente se detiene");
        return NULL;
    }

    SDL_Joystick *joystick = NULL;

    for (;;) {
        int fd = conectar_demonio();
        if (fd < 0) {
            // El demonio aún no está listo: reintenta sin gastar CPU.
            sleep(2);
            continue;
        }
        registrar("conectado al demonio");

        if (!joystick) {
            joystick = crear_joystick_virtual();
            if (!joystick) {
                close(fd);
                sleep(5);
                continue;
            }
        }

        uint8_t trama[TAMANO_TRAMA];
        while (leer_completo(fd, trama, sizeof(trama))) {
            if (leer_u32(trama) != MAGIA_TRAMA) continue;  // resincroniza
            aplicar_estado(joystick, trama);
        }

        registrar("se perdió la conexión con el demonio; reintentando");
        close(fd);
        sleep(2);
    }
    return NULL;
}

__attribute__((constructor))
static void iniciar_puente(void) {
    registrar("shim cargada en el proceso");
    // Sólo actuamos dentro de winedevice.exe, que es quien aloja winebus.
    pthread_t hilo;
    if (pthread_create(&hilo, NULL, hilo_puente, NULL) == 0) {
        pthread_detach(hilo);
    }
}
