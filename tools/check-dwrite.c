/* Verify Wine's TTC header reader without World Creator or large allocations.
 * Build with MinGW: x86_64-w64-mingw32-gcc check-dwrite.c -o check-dwrite.exe -luuid
 * A one-face header must report one face. Poison padding exposes short reads.
 * Upstream fix: wine-mirror/wine a6fc12e4a94bf4dae2d5c3a297794107627dad0a.
 */
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <dwrite.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const unsigned char header[16] = {'t','t','c','f',0,1,0,0,0,0,0,1,0,0,0,16};
static HRESULT WINAPI stream_query(IDWriteFontFileStream *self, REFIID iid, void **out) {
    *out = NULL;
    if (!IsEqualIID(iid, &IID_IUnknown) && !IsEqualIID(iid, &IID_IDWriteFontFileStream)) return E_NOINTERFACE;
    *out = self; return S_OK;
}
static ULONG WINAPI stream_ref(IDWriteFontFileStream *self) { (void)self; return 2; }
static HRESULT WINAPI fragment(IDWriteFontFileStream *self, const void **out, UINT64 offset, UINT64 size, void **context) {
    (void)self; *out = NULL; *context = NULL;
    if (offset > sizeof(header) || size > sizeof(header)-offset) return E_FAIL;
    unsigned char *data = malloc((size_t)size + 4);
    if (!data) return E_OUTOFMEMORY;
    memcpy(data, header + offset, (size_t)size);
    memset(data + size, 0xa5, 4);
    *out = data; *context = data;
    printf("fragment offset=%llu size=%llu\n", (unsigned long long)offset, (unsigned long long)size);
    return S_OK;
}
static void WINAPI release_fragment(IDWriteFontFileStream *self, void *context) { (void)self; free(context); }
static HRESULT WINAPI stream_size(IDWriteFontFileStream *self, UINT64 *out) { (void)self; *out = sizeof(header); return S_OK; }
static HRESULT WINAPI stream_time(IDWriteFontFileStream *self, UINT64 *out) { (void)self; *out = 0; return E_NOTIMPL; }
static IDWriteFontFileStreamVtbl stream_vtbl = {stream_query,stream_ref,stream_ref,fragment,release_fragment,stream_size,stream_time};
static IDWriteFontFileStream stream = {&stream_vtbl};
static HRESULT WINAPI loader_query(IDWriteFontFileLoader *self, REFIID iid, void **out) {
    *out = NULL;
    if (!IsEqualIID(iid,&IID_IUnknown) && !IsEqualIID(iid,&IID_IDWriteFontFileLoader)) return E_NOINTERFACE;
    *out = self; return S_OK;
}
static ULONG WINAPI loader_ref(IDWriteFontFileLoader *self) { (void)self; return 2; }
static HRESULT WINAPI create_stream(IDWriteFontFileLoader *self, const void *key, UINT32 size, IDWriteFontFileStream **out) {
    (void)self; (void)key; (void)size; *out = &stream; return S_OK;
}
static IDWriteFontFileLoaderVtbl loader_vtbl = {loader_query,loader_ref,loader_ref,create_stream};
static IDWriteFontFileLoader loader = {&loader_vtbl};
int main(void) {
    IDWriteFactory *factory = NULL;
    IDWriteFontFile *file = NULL;
    BOOL supported = FALSE;
    DWRITE_FONT_FILE_TYPE type;
    DWRITE_FONT_FACE_TYPE face;
    UINT32 count = 0, key = 1;
    HMODULE module = LoadLibraryW(L"dwrite.dll");
    if (!module) { printf("LoadLibrary error=%lu\n", GetLastError()); return 2; }
    HRESULT (WINAPI *create_factory)(DWRITE_FACTORY_TYPE,REFIID,IUnknown **) = (void *)GetProcAddress(module,"DWriteCreateFactory");
    if (!create_factory) return 2;
    HRESULT hr = create_factory(DWRITE_FACTORY_TYPE_ISOLATED,&IID_IDWriteFactory,(IUnknown **)&factory);
    if (FAILED(hr)) return 2;
    hr = IDWriteFactory_RegisterFontFileLoader(factory,&loader);
    if (SUCCEEDED(hr)) hr = IDWriteFactory_CreateCustomFontFileReference(factory,&key,sizeof(key),&loader,&file);
    if (SUCCEEDED(hr)) hr = IDWriteFontFile_Analyze(file,&supported,&type,&face,&count);
    printf("Analyze hr=%08lx supported=%d faces=%u expected=1\n",(unsigned long)hr,supported,count);
    if (file) IDWriteFontFile_Release(file);
    IDWriteFactory_UnregisterFontFileLoader(factory,&loader);
    IDWriteFactory_Release(factory);
    return FAILED(hr) || !supported || count != 1;
}
