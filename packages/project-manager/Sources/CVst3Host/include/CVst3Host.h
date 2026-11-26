#ifndef CVST3HOST_H
#define CVST3HOST_H

#include <stddef.h>
#include <stdint.h>

// A minimal, offline VST3 host: just enough of the VST3 COM interfaces to load
// a plugin bundle, push a state blob into it, and read back its state and
// parameter list. No audio processing, no editor. macOS has no native VST3
// hosting, and pulling in the full SDK for this would be overkill.
//
// Bundles stay loaded for the life of the process (unloading plugin code is a
// classic source of crashes).

typedef struct {
  uint8_t cid[16];
  char category[32];
  char name[64];
} v3_class_info;

typedef struct {
  uint32_t id;
  char title[256];  // UTF-8
  int32_t step_count;
  int32_t flags;
  double normalized;  // current value, read from the controller
} v3_param_info;

typedef struct v3_plugin v3_plugin;

// Enumerate the classes a bundle exports. Writes up to `max` entries and
// returns the total class count, or -1 if the bundle can't be loaded (e.g. it
// has no slice for this CPU architecture).
int v3_list_classes(const char *bundle_path, v3_class_info *out, int max);

// Instantiate the audio-module class `cid` from `bundle_path` and its edit
// controller. Returns NULL on failure, with a reason in `err`.
v3_plugin *v3_open(const char *bundle_path, const uint8_t cid[16], char *err, size_t err_len);
void v3_close(v3_plugin *p);

// Push a state blob into the component (IComponent::setState). Returns 0 on
// success, else the plugin's tresult.
int v3_set_state(v3_plugin *p, const uint8_t *data, size_t len);

// Mirror the component's current state into the controller
// (setComponentState), so parameter values reflect it.
int v3_sync_controller(v3_plugin *p);

// Read the component / controller state. Allocates *out via malloc (caller
// frees). Returns 0 on success.
int v3_get_component_state(v3_plugin *p, uint8_t **out, size_t *out_len);
int v3_get_controller_state(v3_plugin *p, uint8_t **out, size_t *out_len);

int v3_param_count(v3_plugin *p);
int v3_param_info_at(v3_plugin *p, int index, v3_param_info *out);

#endif
