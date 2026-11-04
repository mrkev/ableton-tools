#include "CVst3Host.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MARK: - VST3 ABI (non-COM-compatible platforms, i.e. macOS)
//
// Hand-declared vtables mirroring pluginterfaces/. Only the slots we call are
// typed; the rest are `void *` placeholders that keep the offsets right.

typedef int32_t tresult;
typedef uint8_t TUID[16];

enum { kResultOk = 0, kNoInterface = -1, kResultFalse = 1, kNotImplemented = 3 };

// INLINE_UID(l1, l2, l3, l4): each 32-bit word stored big-endian.
#define B4(x) (uint8_t)((x) >> 24), (uint8_t)((x) >> 16), (uint8_t)((x) >> 8), (uint8_t)(x)
#define IID(a, b, c, d) {B4(a), B4(b), B4(c), B4(d)}

static const TUID FUnknown_iid = IID(0x00000000, 0x00000000, 0xC0000000, 0x00000046);
static const TUID IComponent_iid = IID(0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802);
static const TUID IEditController_iid = IID(0xDCD7BBE3, 0x7742448D, 0xA874AACC, 0x979C759E);
static const TUID IConnectionPoint_iid = IID(0x70A4156F, 0x6E6E4026, 0x989148BF, 0xAA60D8D1);
static const TUID IBStream_iid = IID(0xC3BF6EA2, 0x30994752, 0x9B6BF990, 0x1EE33E9B);
static const TUID IHostApplication_iid = IID(0x58E595CC, 0xDB2D4969, 0x8B6AAF8C, 0x36A664E5);
static const TUID IComponentHandler_iid = IID(0x93A0BEA3, 0x0BD045DB, 0x8E890B0C, 0xC1E46AC6);

#define FUNKNOWN_METHODS(T)                                     \
  tresult (*queryInterface)(T * self, const TUID iid, void **obj); \
  uint32_t (*addRef)(T * self);                                 \
  uint32_t (*release)(T * self);

typedef struct { int8_t cid[16]; int32_t cardinality; char category[32]; char name[64]; } PClassInfo;

typedef struct {
  uint32_t id;
  uint16_t title[128];
  uint16_t shortTitle[128];
  uint16_t units[128];
  int32_t stepCount;
  double defaultNormalizedValue;
  int32_t unitId;
  int32_t flags;
} ParameterInfo;

typedef struct IBStream IBStream;
typedef struct FUnknown { struct { FUNKNOWN_METHODS(struct FUnknown) } *v; } FUnknown;

typedef struct IPluginFactory IPluginFactory;
struct IPluginFactory {
  struct {
    FUNKNOWN_METHODS(IPluginFactory)
    void *getFactoryInfo;
    int32_t (*countClasses)(IPluginFactory *self);
    tresult (*getClassInfo)(IPluginFactory *self, int32_t index, PClassInfo *info);
    tresult (*createInstance)(IPluginFactory *self, const char *cid, const char *iid, void **obj);
  } *v;
};

typedef struct IComponent IComponent;
struct IComponent {
  struct {
    FUNKNOWN_METHODS(IComponent)
    tresult (*initialize)(IComponent *self, FUnknown *context);
    tresult (*terminate)(IComponent *self);
    tresult (*getControllerClassId)(IComponent *self, TUID classId);
    void *setIoMode, *getBusCount, *getBusInfo, *getRoutingInfo, *activateBus, *setActive;
    tresult (*setState)(IComponent *self, IBStream *state);
    tresult (*getState)(IComponent *self, IBStream *state);
  } *v;
};

typedef struct IEditController IEditController;
struct IEditController {
  struct {
    FUNKNOWN_METHODS(IEditController)
    tresult (*initialize)(IEditController *self, FUnknown *context);
    tresult (*terminate)(IEditController *self);
    tresult (*setComponentState)(IEditController *self, IBStream *state);
    tresult (*setState)(IEditController *self, IBStream *state);
    tresult (*getState)(IEditController *self, IBStream *state);
    int32_t (*getParameterCount)(IEditController *self);
    tresult (*getParameterInfo)(IEditController *self, int32_t index, ParameterInfo *info);
    void *getParamStringByValue, *getParamValueByString;
    void *normalizedParamToPlain, *plainParamToNormalized;
    double (*getParamNormalized)(IEditController *self, uint32_t id);
    void *setParamNormalized;
    tresult (*setComponentHandler)(IEditController *self, FUnknown *handler);
    void *createView;
  } *v;
};

typedef struct IConnectionPoint IConnectionPoint;
struct IConnectionPoint {
  struct {
    FUNKNOWN_METHODS(IConnectionPoint)
    tresult (*connect)(IConnectionPoint *self, IConnectionPoint *other);
    tresult (*disconnect)(IConnectionPoint *self, IConnectionPoint *other);
    void *notify;
  } *v;
};

// MARK: - Host-side objects

// Memory-backed IBStream.
typedef struct {
  FUNKNOWN_METHODS(IBStream)
  tresult (*read)(IBStream *self, void *buffer, int32_t numBytes, int32_t *numBytesRead);
  tresult (*write)(IBStream *self, void *buffer, int32_t numBytes, int32_t *numBytesWritten);
  tresult (*seek)(IBStream *self, int64_t pos, int32_t mode, int64_t *result);
  tresult (*tell)(IBStream *self, int64_t *pos);
} IBStreamVtbl;

struct IBStream {
  const IBStreamVtbl *v;
  uint32_t refs;
  uint8_t *data;
  size_t size, cap, pos;
};

static tresult stream_qi(IBStream *self, const TUID iid, void **obj) {
  if (!memcmp(iid, FUnknown_iid, 16) || !memcmp(iid, IBStream_iid, 16)) {
    self->v->addRef(self);
    *obj = self;
    return kResultOk;
  }
  *obj = NULL;
  return kNoInterface;
}
static uint32_t stream_addRef(IBStream *self) { return ++self->refs; }
static uint32_t stream_release(IBStream *self) {
  if (--self->refs == 0) {
    free(self->data);
    free(self);
    return 0;
  }
  return self->refs;
}
static tresult stream_read(IBStream *self, void *buffer, int32_t n, int32_t *nRead) {
  size_t avail = self->size - self->pos;
  size_t take = n < 0 ? 0 : ((size_t)n < avail ? (size_t)n : avail);
  memcpy(buffer, self->data + self->pos, take);
  self->pos += take;
  if (nRead) *nRead = (int32_t)take;
  return kResultOk;
}
static tresult stream_write(IBStream *self, void *buffer, int32_t n, int32_t *nWritten) {
  if (n < 0) return kResultFalse;
  size_t end = self->pos + (size_t)n;
  if (end > self->cap) {
    size_t cap = self->cap ? self->cap : 4096;
    while (cap < end) cap *= 2;
    uint8_t *grown = realloc(self->data, cap);
    if (!grown) return kResultFalse;
    self->data = grown;
    self->cap = cap;
  }
  memcpy(self->data + self->pos, buffer, (size_t)n);
  self->pos = end;
  if (end > self->size) self->size = end;
  if (nWritten) *nWritten = n;
  return kResultOk;
}
static tresult stream_seek(IBStream *self, int64_t pos, int32_t mode, int64_t *result) {
  int64_t base = mode == 1 ? (int64_t)self->pos : mode == 2 ? (int64_t)self->size : 0;
  int64_t target = base + pos;
  if (target < 0) return kResultFalse;
  if ((size_t)target > self->size) {  // grow with zeros, as the SDK's MemoryStream does
    int32_t ignored;
    self->pos = self->size;
    size_t pad = (size_t)target - self->size;
    uint8_t *zeros = calloc(1, pad);
    stream_write(self, zeros, (int32_t)pad, &ignored);
    free(zeros);
  }
  self->pos = (size_t)target;
  if (result) *result = target;
  return kResultOk;
}
static tresult stream_tell(IBStream *self, int64_t *pos) {
  if (pos) *pos = (int64_t)self->pos;
  return kResultOk;
}

static const IBStreamVtbl stream_vtbl = {
    stream_qi, stream_addRef, stream_release, stream_read, stream_write, stream_seek, stream_tell,
};

static IBStream *stream_new(const uint8_t *data, size_t len) {
  IBStream *s = calloc(1, sizeof *s);
  s->v = &stream_vtbl;
  s->refs = 1;
  if (len) {
    int32_t ignored;
    stream_write(s, (void *)data, (int32_t)len, &ignored);
    s->pos = 0;
  }
  return s;
}

// Static IHostApplication + no-op IComponentHandler. Both are process-lifetime
// singletons, so ref counting is a no-op.
typedef struct Host Host;
typedef struct {
  FUNKNOWN_METHODS(Host)
  tresult (*getName)(Host *self, uint16_t name[128]);
  tresult (*createInstance)(Host *self, TUID cid, TUID iid, void **obj);
} HostVtbl;
struct Host { const HostVtbl *v; };

typedef struct Handler Handler;
typedef struct {
  FUNKNOWN_METHODS(Handler)
  tresult (*beginEdit)(Handler *self, uint32_t id);
  tresult (*performEdit)(Handler *self, uint32_t id, double value);
  tresult (*endEdit)(Handler *self, uint32_t id);
  tresult (*restartComponent)(Handler *self, int32_t flags);
} HandlerVtbl;
struct Handler { const HandlerVtbl *v; };

static Host host;
static Handler handler;

static tresult host_qi(Host *self, const TUID iid, void **obj) {
  if (!memcmp(iid, FUnknown_iid, 16) || !memcmp(iid, IHostApplication_iid, 16)) {
    *obj = self;
    return kResultOk;
  }
  *obj = NULL;
  return kNoInterface;
}
static uint32_t host_ref(Host *self) { (void)self; return 1; }
static tresult host_getName(Host *self, uint16_t name[128]) {
  (void)self;
  const char *n = "Ableton Device Converter";
  size_t i = 0;
  for (; n[i] && i < 127; i++) name[i] = (uint16_t)n[i];
  name[i] = 0;
  return kResultOk;
}
static tresult host_createInstance(Host *self, TUID cid, TUID iid, void **obj) {
  (void)self; (void)cid; (void)iid;
  *obj = NULL;
  return kNotImplemented;  // no IMessage / IAttributeList support
}
static const HostVtbl host_vtbl = {host_qi, host_ref, host_ref, host_getName, host_createInstance};

static tresult handler_qi(Handler *self, const TUID iid, void **obj) {
  if (!memcmp(iid, FUnknown_iid, 16) || !memcmp(iid, IComponentHandler_iid, 16)) {
    *obj = self;
    return kResultOk;
  }
  *obj = NULL;
  return kNoInterface;
}
static uint32_t handler_ref(Handler *self) { (void)self; return 1; }
static tresult handler_edit(Handler *self, uint32_t id) { (void)self; (void)id; return kResultOk; }
static tresult handler_perform(Handler *self, uint32_t id, double v) {
  (void)self; (void)id; (void)v;
  return kResultOk;
}
static tresult handler_restart(Handler *self, int32_t flags) { (void)self; (void)flags; return kResultOk; }
static const HandlerVtbl handler_vtbl = {
    handler_qi, handler_ref, handler_ref, handler_edit, handler_perform, handler_edit, handler_restart,
};

static void init_host_objects(void) {
  host.v = &host_vtbl;
  handler.v = &handler_vtbl;
}

// MARK: - Bundle loading (cached for the process lifetime)

typedef struct LoadedBundle {
  char *path;
  IPluginFactory *factory;
  struct LoadedBundle *next;
} LoadedBundle;

static LoadedBundle *loaded;

static IPluginFactory *factory_for(const char *path) {
  for (LoadedBundle *b = loaded; b; b = b->next)
    if (!strcmp(b->path, path)) return b->factory;

  init_host_objects();
  IPluginFactory *factory = NULL;
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), true);
  CFBundleRef bundle = url ? CFBundleCreate(NULL, url) : NULL;
  if (url) CFRelease(url);
  if (bundle && CFBundleLoadExecutable(bundle)) {
    bool (*entry)(CFBundleRef) = CFBundleGetFunctionPointerForName(bundle, CFSTR("bundleEntry"));
    IPluginFactory *(*getFactory)(void) = CFBundleGetFunctionPointerForName(bundle, CFSTR("GetPluginFactory"));
    if (getFactory && (!entry || entry(bundle))) factory = getFactory();
  }
  // Cache failures too, so a broken bundle isn't retried.
  LoadedBundle *b = calloc(1, sizeof *b);
  b->path = strdup(path);
  b->factory = factory;
  b->next = loaded;
  loaded = b;
  return factory;
}

int v3_list_classes(const char *bundle_path, v3_class_info *out, int max) {
  IPluginFactory *f = factory_for(bundle_path);
  if (!f) return -1;
  int32_t n = f->v->countClasses(f);
  for (int32_t i = 0; i < n && i < max; i++) {
    PClassInfo ci;
    memset(&ci, 0, sizeof ci);
    f->v->getClassInfo(f, i, &ci);
    memcpy(out[i].cid, ci.cid, 16);
    memcpy(out[i].category, ci.category, sizeof out[i].category);
    memcpy(out[i].name, ci.name, sizeof out[i].name);
    out[i].category[sizeof out[i].category - 1] = 0;
    out[i].name[sizeof out[i].name - 1] = 0;
  }
  return n;
}

// MARK: - Plugin instances

struct v3_plugin {
  IComponent *component;
  IEditController *controller;
  bool controllerIsComponent;
  IConnectionPoint *componentCP, *controllerCP;
};

static void set_err(char *err, size_t len, const char *msg) {
  if (err && len) snprintf(err, len, "%s", msg);
}

v3_plugin *v3_open(const char *bundle_path, const uint8_t cid[16], char *err, size_t err_len) {
  IPluginFactory *f = factory_for(bundle_path);
  if (!f) {
    set_err(err, err_len, "couldn't load bundle (missing native architecture?)");
    return NULL;
  }
  v3_plugin *p = calloc(1, sizeof *p);
  if (f->v->createInstance(f, (const char *)cid, (const char *)IComponent_iid, (void **)&p->component) != kResultOk
      || !p->component) {
    set_err(err, err_len, "factory couldn't create the component");
    free(p);
    return NULL;
  }
  if (p->component->v->initialize(p->component, (FUnknown *)&host) != kResultOk) {
    set_err(err, err_len, "component initialize failed");
    p->component->v->release(p->component);
    free(p);
    return NULL;
  }

  // Single-component plugins implement IEditController on the component.
  if (p->component->v->queryInterface(p->component, IEditController_iid, (void **)&p->controller) == kResultOk
      && p->controller) {
    p->controllerIsComponent = true;
  } else {
    TUID ctrlCid;
    p->controller = NULL;
    if (p->component->v->getControllerClassId(p->component, ctrlCid) == kResultOk
        && f->v->createInstance(f, (const char *)ctrlCid, (const char *)IEditController_iid,
                                (void **)&p->controller) == kResultOk
        && p->controller) {
      if (p->controller->v->initialize(p->controller, (FUnknown *)&host) != kResultOk) {
        p->controller->v->release(p->controller);
        p->controller = NULL;
      }
    }
    if (!p->controller) {
      set_err(err, err_len, "couldn't create the edit controller");
      v3_close(p);
      return NULL;
    }
    // Connect component <-> controller (JUCE wires its parameters this way).
    p->component->v->queryInterface(p->component, IConnectionPoint_iid, (void **)&p->componentCP);
    p->controller->v->queryInterface(p->controller, IConnectionPoint_iid, (void **)&p->controllerCP);
    if (p->componentCP && p->controllerCP) {
      p->componentCP->v->connect(p->componentCP, p->controllerCP);
      p->controllerCP->v->connect(p->controllerCP, p->componentCP);
    }
  }
  p->controller->v->setComponentHandler(p->controller, (FUnknown *)&handler);
  return p;
}

void v3_close(v3_plugin *p) {
  if (!p) return;
  if (p->componentCP && p->controllerCP) {
    p->componentCP->v->disconnect(p->componentCP, p->controllerCP);
    p->controllerCP->v->disconnect(p->controllerCP, p->componentCP);
  }
  if (p->componentCP) p->componentCP->v->release(p->componentCP);
  if (p->controllerCP) p->controllerCP->v->release(p->controllerCP);
  if (p->controller) {
    p->controller->v->setComponentHandler(p->controller, NULL);
    if (!p->controllerIsComponent) p->controller->v->terminate(p->controller);
    p->controller->v->release(p->controller);
  }
  if (p->component) {
    p->component->v->terminate(p->component);
    p->component->v->release(p->component);
  }
  free(p);
}

int v3_set_state(v3_plugin *p, const uint8_t *data, size_t len) {
  IBStream *s = stream_new(data, len);
  tresult r = p->component->v->setState(p->component, s);
  s->v->release(s);
  return r;
}

int v3_sync_controller(v3_plugin *p) {
  // Hand the controller the component's state as the plugin itself now
  // reports it, which is what a host does after loading.
  IBStream *s = stream_new(NULL, 0);
  tresult r = p->component->v->getState(p->component, s);
  if (r == kResultOk) {
    s->pos = 0;
    r = p->controller->v->setComponentState(p->controller, s);
  }
  s->v->release(s);
  return r;
}

static int take_stream(IBStream *s, tresult r, uint8_t **out, size_t *out_len) {
  if (r == kResultOk) {
    *out = malloc(s->size ? s->size : 1);
    memcpy(*out, s->data, s->size);
    *out_len = s->size;
  }
  s->v->release(s);
  return r;
}

int v3_get_component_state(v3_plugin *p, uint8_t **out, size_t *out_len) {
  IBStream *s = stream_new(NULL, 0);
  return take_stream(s, p->component->v->getState(p->component, s), out, out_len);
}

int v3_get_controller_state(v3_plugin *p, uint8_t **out, size_t *out_len) {
  IBStream *s = stream_new(NULL, 0);
  return take_stream(s, p->controller->v->getState(p->controller, s), out, out_len);
}

int v3_param_count(v3_plugin *p) { return p->controller->v->getParameterCount(p->controller); }

int v3_param_info_at(v3_plugin *p, int index, v3_param_info *out) {
  ParameterInfo info;
  memset(&info, 0, sizeof info);
  tresult r = p->controller->v->getParameterInfo(p->controller, index, &info);
  if (r != kResultOk) return r;
  out->id = info.id;
  out->step_count = info.stepCount;
  out->flags = info.flags;
  out->normalized = p->controller->v->getParamNormalized(p->controller, info.id);
  CFIndex n = 0;
  while (n < 128 && info.title[n]) n++;
  CFStringRef title = CFStringCreateWithCharacters(NULL, info.title, n);
  out->title[0] = 0;
  if (title) {
    CFStringGetCString(title, out->title, sizeof out->title, kCFStringEncodingUTF8);
    CFRelease(title);
  }
  return kResultOk;
}
