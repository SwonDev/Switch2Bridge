// inyector.c — da de alta el mando dentro de cualquier proceso que use SDL.
//
// Se carga con DYLD_INSERT_LIBRARIES en Steam para macOS (su binario real no
// tiene hardened runtime) y, por herencia del entorno, en los juegos que Steam
// lanza. Detecta en tiempo de ejecución si el proceso lleva SDL2 o SDL3 y usa
// la API correspondiente; si no encuentra ninguna, se retira sin hacer nada.
//
// Es deliberadamente defensivo: se carga en procesos ajenos, así que ante
// cualquier duda prefiere no actuar.

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define MAGIA_TRAMA 0x53325031u
#define TAMANO_TRAMA 20
#define SDL_INIT_JOYSTICK 0x00000200u
#define TIPO_GAMEPAD 1

#define NUM_EJES 6
#define NUM_BOTONES 15

// Máscara de botones del mando (ver Protocolo.swift).
#define BTN_Y 0x00000001u
#define BTN_X 0x00000002u
#define BTN_B 0x00000004u
#define BTN_A 0x00000008u
#define BTN_R 0x00000040u
#define BTN_MENOS 0x00000100u
#define BTN_MAS 0x00000200u
#define BTN_STICK_DER 0x00000400u
#define BTN_STICK_IZQ 0x00000800u
#define BTN_HOME 0x00001000u
#define BTN_ABAJO 0x00010000u
#define BTN_ARRIBA 0x00020000u
#define BTN_DERECHA 0x00040000u
#define BTN_IZQUIERDA 0x00080000u
#define BTN_L 0x00400000u

// ---------------------------------------------------------------------------
// Punteros resueltos en tiempo de ejecución
// ---------------------------------------------------------------------------

static uint32_t (*p_WasInit)(uint32_t);

// SDL2
static int   (*p2_AttachVirtual)(int, int, int, int);
static void *(*p2_JoystickOpen)(int);
static int   (*p2_SetAxis)(void *, int, int16_t);
static int   (*p2_SetButton)(void *, int, uint8_t);

// SDL3
static uint32_t (*p3_AttachVirtual)(const void *);
static void *(*p3_OpenJoystick)(uint32_t);
static int   (*p3_SetAxis)(void *, int, int16_t);
static int   (*p3_SetButton)(void *, int, int);
static int   (*p3_DetachVirtual)(uint32_t);
static int   (*p3_NumAxes)(void *);

static const char *(*p_GetError)(void);

static int version_sdl = 0;  // 0 = ninguna, 2 = SDL2, 3 = SDL3

/// Descriptor de joystick virtual de SDL3.
///
/// Se rellena sobre un búfer amplio puesto a cero: si la disposición real del
/// struct variase entre versiones, los campos que no reconozcamos quedan a cero
/// y SDL aplica sus valores por defecto en lugar de leer basura.
typedef struct {
    uint32_t version;
    uint16_t type;
    uint16_t relleno;
    uint16_t vendor_id;
    uint16_t product_id;
    uint16_t naxes;
    uint16_t nbuttons;
    uint16_t nballs;
    uint16_t nhats;
    uint16_t ntouchpads;
    uint16_t nsensors;
    uint16_t relleno2[2];
    uint32_t button_mask;
    uint32_t axis_mask;
    const char *name;
} DescriptorSDL3;

static void registrar(const char *formato, ...) {
    const char *hogar = getenv("HOME");
    if (!hogar) return;
    char ruta[512];
    snprintf(ruta, sizeof(ruta), "%s/Library/Application Support/Switch2Bridge/inyector.log", hogar);
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

/// Busca la API de SDL ya cargada en este proceso. No carga nada nuevo.
static int detectar_sdl(void) {
    p_WasInit = dlsym(RTLD_DEFAULT, "SDL_WasInit");
    if (!p_WasInit) return 0;

    p_GetError       = dlsym(RTLD_DEFAULT, "SDL_GetError");
    p3_DetachVirtual = dlsym(RTLD_DEFAULT, "SDL_DetachVirtualJoystick");
    p3_NumAxes       = dlsym(RTLD_DEFAULT, "SDL_GetNumJoystickAxes");

    p3_AttachVirtual = dlsym(RTLD_DEFAULT, "SDL_AttachVirtualJoystick");
    p3_OpenJoystick  = dlsym(RTLD_DEFAULT, "SDL_OpenJoystick");
    p3_SetAxis       = dlsym(RTLD_DEFAULT, "SDL_SetJoystickVirtualAxis");
    p3_SetButton     = dlsym(RTLD_DEFAULT, "SDL_SetJoystickVirtualButton");
    if (p3_AttachVirtual && p3_OpenJoystick && p3_SetAxis && p3_SetButton) return 3;

    p2_AttachVirtual = dlsym(RTLD_DEFAULT, "SDL_JoystickAttachVirtual");
    p2_JoystickOpen  = dlsym(RTLD_DEFAULT, "SDL_JoystickOpen");
    p2_SetAxis       = dlsym(RTLD_DEFAULT, "SDL_JoystickSetVirtualAxis");
    p2_SetButton     = dlsym(RTLD_DEFAULT, "SDL_JoystickSetVirtualButton");
    if (p2_AttachVirtual && p2_JoystickOpen && p2_SetAxis && p2_SetButton) return 2;

    return 0;
}

static int conectar_demonio(void) {
    const char *hogar = getenv("HOME");
    if (!hogar) return -1;
    char ruta[512];
    snprintf(ruta, sizeof(ruta), "%s/Library/Application Support/Switch2Bridge/estado.sock", hogar);

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

static int leer_completo(int fd, void *bufer, size_t n) {
    uint8_t *p = bufer;
    size_t restantes = n;
    while (restantes > 0) {
        ssize_t leidos = read(fd, p, restantes);
        if (leidos > 0) { p += leidos; restantes -= (size_t)leidos; }
        else if (leidos < 0 && errno == EINTR) continue;
        else return 0;
    }
    return 1;
}

static int16_t leer_i16(const uint8_t *p) { return (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t leer_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void poner_boton(void *joy, int indice, int pulsado) {
    if (version_sdl == 3) p3_SetButton(joy, indice, pulsado);
    else p2_SetButton(joy, indice, (uint8_t)(pulsado ? 1 : 0));
}

static void poner_eje(void *joy, int indice, int16_t valor) {
    if (version_sdl == 3) p3_SetAxis(joy, indice, valor);
    else p2_SetAxis(joy, indice, valor);
}

static void aplicar_estado(void *joy, const uint8_t *trama) {
    uint32_t b = leer_u32(trama + 4);

    poner_eje(joy, 0, leer_i16(trama + 8));
    poner_eje(joy, 1, leer_i16(trama + 10));
    poner_eje(joy, 2, leer_i16(trama + 12));
    poner_eje(joy, 3, leer_i16(trama + 14));
    poner_eje(joy, 4, (int16_t)((int)trama[16] * 32767 / 255));
    poner_eje(joy, 5, (int16_t)((int)trama[17] * 32767 / 255));

    // Disposición Xbox por posición física: el botón de abajo del mando de
    // Nintendo (rotulado B) es la A de Xbox, y así con el resto.
    poner_boton(joy, 0,  (b & BTN_B) != 0);          // A
    poner_boton(joy, 1,  (b & BTN_A) != 0);          // B
    poner_boton(joy, 2,  (b & BTN_Y) != 0);          // X
    poner_boton(joy, 3,  (b & BTN_X) != 0);          // Y
    poner_boton(joy, 4,  (b & BTN_MENOS) != 0);      // Back
    poner_boton(joy, 5,  (b & BTN_HOME) != 0);       // Guide
    poner_boton(joy, 6,  (b & BTN_MAS) != 0);        // Start
    poner_boton(joy, 7,  (b & BTN_STICK_IZQ) != 0);
    poner_boton(joy, 8,  (b & BTN_STICK_DER) != 0);
    poner_boton(joy, 9,  (b & BTN_L) != 0);
    poner_boton(joy, 10, (b & BTN_R) != 0);
    poner_boton(joy, 11, (b & BTN_ARRIBA) != 0);
    poner_boton(joy, 12, (b & BTN_ABAJO) != 0);
    poner_boton(joy, 13, (b & BTN_IZQUIERDA) != 0);
    poner_boton(joy, 14, (b & BTN_DERECHA) != 0);
}

static void *crear_joystick(void) {
    if (version_sdl == 3) {
        // SDL3 versiona sus interfaces POR TAMAÑO: `version` debe valer
        // sizeof(SDL_VirtualJoystickDesc), que cambia entre versiones de SDL.
        // En vez de fijar un número que envejecería mal, lo sondeamos y
        // validamos el resultado contando los ejes del mando resultante.
        for (uint32_t tam = 64; tam <= 240; tam += 4) {
            uint8_t bufer[256];
            memset(bufer, 0, sizeof(bufer));
            DescriptorSDL3 *d = (DescriptorSDL3 *)bufer;
            d->version     = tam;
            d->type        = TIPO_GAMEPAD;
            d->vendor_id   = 0x057E;
            d->product_id  = 0x2069;
            d->naxes       = NUM_EJES;
            d->nbuttons    = NUM_BOTONES;
            d->button_mask = (1u << NUM_BOTONES) - 1u;
            d->axis_mask   = (1u << NUM_EJES) - 1u;
            d->name        = "Nintendo Switch 2 Pro Controller";

            uint32_t id = p3_AttachVirtual(bufer);
            if (id == 0) continue;

            void *joy = p3_OpenJoystick(id);
            // Comprobación de cordura: si la disposición no cuadrase, el número
            // de ejes no coincidiría y preferimos seguir buscando.
            if (joy && (!p3_NumAxes || p3_NumAxes(joy) == NUM_EJES)) {
                registrar("SDL3: joystick virtual dado de alta (id %u, sizeof desc = %u)", id, tam);
                return joy;
            }
            if (p3_DetachVirtual) p3_DetachVirtual(id);
        }
        registrar("SDL3: no se pudo dar de alta el joystick virtual (%s)",
                  p_GetError ? p_GetError() : "sin detalle");
        return NULL;
    }

    int indice = p2_AttachVirtual(TIPO_GAMEPAD, NUM_EJES, NUM_BOTONES, 0);
    if (indice < 0) {
        registrar("SDL2: no se pudo dar de alta el joystick virtual");
        return NULL;
    }
    void *joy = p2_JoystickOpen(indice);
    registrar("SDL2: joystick virtual dado de alta (índice %d)", indice);
    return joy;
}

static void *hilo(void *sinUsar) {
    (void)sinUsar;

    // Espera a que el proceso cargue e inicialice SDL (los juegos lo hacen al
    // arrancar, pero no en el primer instante).
    void *joy = NULL;
    for (int intento = 0; intento < 1200; intento++) {  // hasta 2 minutos
        if (version_sdl == 0) version_sdl = detectar_sdl();
        if (version_sdl != 0 && (p_WasInit(SDL_INIT_JOYSTICK) & SDL_INIT_JOYSTICK)) break;
        usleep(100 * 1000);
    }
    if (version_sdl == 0) return NULL;                      // proceso sin SDL: nos retiramos
    if (!(p_WasInit(SDL_INIT_JOYSTICK) & SDL_INIT_JOYSTICK)) return NULL;

    registrar("SDL%d detectada en este proceso", version_sdl);

    for (;;) {
        int fd = conectar_demonio();
        if (fd < 0) { sleep(2); continue; }

        if (!joy) {
            joy = crear_joystick();
            if (!joy) { close(fd); sleep(5); continue; }
        }

        uint8_t trama[TAMANO_TRAMA];
        while (leer_completo(fd, trama, sizeof(trama))) {
            if (leer_u32(trama) != MAGIA_TRAMA) continue;
            aplicar_estado(joy, trama);
        }
        close(fd);
        sleep(2);
    }
    return NULL;
}

__attribute__((constructor))
static void arrancar(void) {
    pthread_t h;
    if (pthread_create(&h, NULL, hilo, NULL) == 0) pthread_detach(h);
}
