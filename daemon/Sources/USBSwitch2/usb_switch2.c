// usb_switch2.c — conmuta el Pro Controller 2 a modo HID estándar por USB.
//
// La secuencia de comandos procede de la ingeniería inversa de la comunidad
// (ikz87 / NSW2-controller-enabler y Switch2ProMac). Una vez enviada, macOS
// enumera el mando como gamepad HID normal y no hace falta ningún puente.

#include "include/usb_switch2.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <unistd.h>

#define VID_NINTENDO 0x057E
#define PID_PRO2     0x2069
#define PID_GAMECUBE 0x2073
#define INTERFAZ_COMANDOS 1

// Secuencia de inicialización. Cada entrada es {longitud, bytes…}.
static const unsigned char SECUENCIA[][30] = {
    {16, 0x03,0x91,0x00,0x0D,0x00,0x08,0x00,0x00,0x01,0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF},
    { 8, 0x07,0x91,0x00,0x01,0x00,0x00,0x00,0x00},
    { 8, 0x16,0x91,0x00,0x01,0x00,0x00,0x00,0x00},
    {22, 0x15,0x91,0x00,0x01,0x00,0x0E,0x00,0x00,0x00,0x02,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF},
    {25, 0x15,0x91,0x00,0x02,0x00,0x11,0x00,0x00,0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF},
    { 9, 0x15,0x91,0x00,0x03,0x00,0x01,0x00,0x00,0x00},
    {16, 0x09,0x91,0x00,0x07,0x00,0x08,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
    {12, 0x0C,0x91,0x00,0x02,0x00,0x04,0x00,0x00,0x27,0x00,0x00,0x00},
    { 8, 0x11,0x91,0x00,0x03,0x00,0x00,0x00,0x00},
    {29, 0x0A,0x91,0x00,0x08,0x00,0x14,0x00,0x00,0x01,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x35,0x00,0x46,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
    {12, 0x0C,0x91,0x00,0x04,0x00,0x04,0x00,0x00,0x27,0x00,0x00,0x00},
    {12, 0x03,0x91,0x00,0x0A,0x00,0x04,0x00,0x00,0x09,0x00,0x00,0x00},
    { 8, 0x10,0x91,0x00,0x01,0x00,0x00,0x00,0x00},
    { 8, 0x01,0x91,0x00,0x0C,0x00,0x00,0x00,0x00},
    { 7, 0x03,0x91,0x00,0x01,0x00,0x00,0x00},
    {11, 0x0A,0x91,0x00,0x02,0x00,0x04,0x00,0x00,0x03,0x00,0x00},
    // Enciende el LED del jugador 1: señal visible de que la secuencia caló.
    {16, 0x09,0x91,0x00,0x07,0x00,0x08,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
};

static const int NUM_COMANDOS = (int)(sizeof(SECUENCIA) / sizeof(SECUENCIA[0]));

/// Construye el diccionario de coincidencia para un VID/PID concretos.
static CFMutableDictionaryRef coincidencia_usb(int producto) {
    CFMutableDictionaryRef dic = IOServiceMatching(kIOUSBDeviceClassName);
    if (!dic) return NULL;

    int fabricante = VID_NINTENDO;
    CFNumberRef nFab = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &fabricante);
    CFNumberRef nPro = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &producto);
    CFDictionarySetValue(dic, CFSTR(kUSBVendorID), nFab);
    CFDictionarySetValue(dic, CFSTR(kUSBProductID), nPro);
    CFRelease(nFab);
    CFRelease(nPro);
    return dic;
}

static io_service_t buscar_mando(int *producto_encontrado) {
    const int productos[] = {PID_PRO2, PID_GAMECUBE};
    for (int i = 0; i < 2; i++) {
        CFMutableDictionaryRef dic = coincidencia_usb(productos[i]);
        if (!dic) continue;
        io_service_t servicio = IOServiceGetMatchingService(kIOMainPortDefault, dic);
        if (servicio) {
            if (producto_encontrado) *producto_encontrado = productos[i];
            return servicio;
        }
    }
    return 0;
}

int switch2_usb_presente(void) {
    io_service_t servicio = buscar_mando(NULL);
    if (!servicio) return 0;
    IOObjectRelease(servicio);
    return 1;
}

/// Obtiene la interfaz de usuario (COM de IOKit) de un servicio dado.
static void *interfaz_de(io_service_t servicio, CFUUIDRef tipoPlugin, CFUUIDRef idInterfaz) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 puntuacion = 0;
    if (IOCreatePlugInInterfaceForService(servicio, tipoPlugin, kIOCFPlugInInterfaceID,
                                          &plugin, &puntuacion) != kIOReturnSuccess || !plugin) {
        return NULL;
    }
    void *interfaz = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(idInterfaz), &interfaz);
    (*plugin)->Release(plugin);
    return interfaz;
}

int switch2_usb_inicializar(void) {
    int producto = 0;
    io_service_t servicio = buscar_mando(&producto);
    if (!servicio) return -1;

    IOUSBDeviceInterface **dispositivo =
        (IOUSBDeviceInterface **)interfaz_de(servicio, kIOUSBDeviceUserClientTypeID,
                                             kIOUSBDeviceInterfaceID);
    IOObjectRelease(servicio);
    if (!dispositivo) return -2;

    int resultado = -2;
    if ((*dispositivo)->USBDeviceOpen(dispositivo) != kIOReturnSuccess) {
        // El mando ya está en modo HID (macOS lo tiene tomado): nada que hacer.
        (*dispositivo)->Release(dispositivo);
        return -2;
    }

    // Asegura que hay una configuración activa antes de buscar interfaces.
    UInt8 numConfigs = 0;
    (*dispositivo)->GetNumberOfConfigurations(dispositivo, &numConfigs);
    if (numConfigs > 0) {
        IOUSBConfigurationDescriptorPtr config = NULL;
        if ((*dispositivo)->GetConfigurationDescriptorPtr(dispositivo, 0, &config) == kIOReturnSuccess && config) {
            (*dispositivo)->SetConfiguration(dispositivo, config->bConfigurationValue);
        }
    }

    IOUSBFindInterfaceRequest peticion;
    peticion.bInterfaceClass    = kIOUSBFindInterfaceDontCare;
    peticion.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    peticion.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    peticion.bAlternateSetting  = kIOUSBFindInterfaceDontCare;

    io_iterator_t iterador = 0;
    if ((*dispositivo)->CreateInterfaceIterator(dispositivo, &peticion, &iterador) != kIOReturnSuccess) {
        (*dispositivo)->USBDeviceClose(dispositivo);
        (*dispositivo)->Release(dispositivo);
        return -3;
    }

    io_service_t servicioInterfaz;
    while ((servicioInterfaz = IOIteratorNext(iterador))) {
        IOUSBInterfaceInterface **interfaz =
            (IOUSBInterfaceInterface **)interfaz_de(servicioInterfaz, kIOUSBInterfaceUserClientTypeID,
                                                    kIOUSBInterfaceInterfaceID);
        IOObjectRelease(servicioInterfaz);
        if (!interfaz) continue;

        UInt8 numero = 0xFF;
        (*interfaz)->GetInterfaceNumber(interfaz, &numero);
        if (numero != INTERFAZ_COMANDOS) {
            (*interfaz)->Release(interfaz);
            continue;
        }

        if ((*interfaz)->USBInterfaceOpen(interfaz) != kIOReturnSuccess) {
            (*interfaz)->Release(interfaz);
            resultado = -2;
            break;
        }

        // Localiza el pipe bulk de salida.
        UInt8 numEndpoints = 0;
        (*interfaz)->GetNumEndpoints(interfaz, &numEndpoints);
        UInt8 pipeSalida = 0;
        for (UInt8 pipe = 1; pipe <= numEndpoints; pipe++) {
            UInt8 direccion = 0, numero_ep = 0, tipo = 0, intervalo = 0;
            UInt16 tamMax = 0;
            if ((*interfaz)->GetPipeProperties(interfaz, pipe, &direccion, &numero_ep,
                                               &tipo, &tamMax, &intervalo) != kIOReturnSuccess) {
                continue;
            }
            if (direccion == kUSBOut && tipo == kUSBBulk) {
                pipeSalida = pipe;
                break;
            }
        }

        if (pipeSalida == 0) {
            (*interfaz)->USBInterfaceClose(interfaz);
            (*interfaz)->Release(interfaz);
            resultado = -3;
            break;
        }

        resultado = 0;
        for (int i = 0; i < NUM_COMANDOS; i++) {
            UInt32 longitud = SECUENCIA[i][0];
            IOReturn r = (*interfaz)->WritePipe(interfaz, pipeSalida,
                                                (void *)&SECUENCIA[i][1], longitud);
            if (r != kIOReturnSuccess) {
                resultado = -4;
                break;
            }
            usleep(50 * 1000);  // el mando necesita respirar entre comandos
        }

        (*interfaz)->USBInterfaceClose(interfaz);
        (*interfaz)->Release(interfaz);
        break;
    }
    IOObjectRelease(iterador);

    (*dispositivo)->USBDeviceClose(dispositivo);
    (*dispositivo)->Release(dispositivo);
    return resultado;
}
