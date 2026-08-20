/*
 * Read-only iOS 17 probe for QuartzCore layers rejected by
 * CA::Render::Update::allowed_in_update().
 *
 * Attach with:
 *   frida -U -n backboardd -l scripts/probes/probe-backboardd-update-mask-frida.js
 *
 * The function hook runs entirely in a CModule and writes rejected samples to
 * a fixed lock-free buffer. JavaScript only drains that buffer periodically,
 * keeping the render-thread probe overhead bounded. The script detaches
 * automatically after 20 seconds.
 */

'use strict';

const quartzCorePath = '/System/Library/Frameworks/QuartzCore.framework/QuartzCore';
const allowedSymbols = [
  '__ZNK2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE',
  '__ZN2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE',
];
const prepareSymbols = [
  '__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPNS0_5LayerERNS1_11LocalState0Ey',
  '__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPKNS0_5LayerERNS1_11LocalState0Ey',
];
const processIDSymbol = '__ZNK2CA6Render7Context10process_idEv';
// iOS 17.0 (21A327), QuartzCore image base 0x189310000 in the matching DSC.
// These are used only when Frida cannot enumerate private DSC C++ symbols.
const ios17Offsets = {
  allowed: 0x292d4,
  prepare: 0x1c9a8,
  processID: 0x29c0c,
};

function findSymbol(candidates, fallbackOffset) {
  const module = Process.getModuleByName('QuartzCore');
  for (const name of candidates) {
    let address = null;
    try {
      address = module.findExportByName(name);
    } catch (_) {
      address = null;
    }
    if (address === null) {
      try {
        const symbol = DebugSymbol.fromName(name);
        if (symbol !== null && symbol.address !== null && !symbol.address.isNull()) {
          address = symbol.address;
        }
      } catch (_) {
        address = null;
      }
    }
    if (address !== null && !address.isNull()) {
      return { name, address };
    }
  }
  if (fallbackOffset !== undefined) {
    const address = module.base.add(fallbackOffset);
    if (Instruction.parse(address).mnemonic !== 'pacibsp') {
      throw new Error(`unverified QuartzCore fallback at ${address}`);
    }
    return { name: `image+0x${fallbackOffset.toString(16)}`, address };
  }
  return null;
}

function decodeBLTarget(address) {
  const raw = address.readU32() >>> 0;
  if (((raw & 0xfc000000) >>> 0) !== 0x94000000) {
    return null;
  }
  let immediate = raw & 0x03ffffff;
  if ((immediate & 0x02000000) !== 0) {
    immediate -= 0x04000000;
  }
  return address.add(immediate * 4);
}

function parseRegister(text, pattern, description) {
  const match = pattern.exec(text);
  if (match === null) {
    throw new Error(`could not parse ${description}: ${text}`);
  }
  return match[1];
}

function findContextPIDOffset(processIDAddress) {
  for (let index = 0; index < 48; index++) {
    const address = processIDAddress.add(index * 4);
    const instruction = Instruction.parse(address);
    const text = instruction.toString();
    const addMatch = /^add (x\d+), x0, #(0x[0-9a-f]+|[0-9]+)$/i.exec(text);
    if (addMatch === null) {
      continue;
    }
    const next = Instruction.parse(address.add(4)).toString();
    const expected = new RegExp(`^ldar w0, \\[${addMatch[1]}\\]$`, 'i');
    if (!expected.test(next)) {
      continue;
    }
    return Number.parseInt(addMatch[2], 0);
  }
  throw new Error('could not derive Context::process_id field offset');
}

function findLayerFlagsOffset(allowedAddress) {
  for (let index = 0; index < 80; index++) {
    const text = Instruction.parse(allowedAddress.add(index * 4)).toString();
    const match = /^ldr w\d+, \[x2, #(0x[0-9a-f]+|[0-9]+)\]$/i.exec(text);
    if (match !== null) {
      return Number.parseInt(match[1], 0);
    }
  }
  throw new Error('could not derive CA::Render::Layer flags offset');
}

function findUpdateFlagsOffset(allowedAddress) {
  for (let index = 0; index < 24; index++) {
    const text = Instruction.parse(allowedAddress.add(index * 4)).toString();
    const match = /^ldr w\d+, \[x0, #(0x[0-9a-f]+|[0-9]+)\]$/i.exec(text);
    if (match !== null) {
      return Number.parseInt(match[1], 0);
    }
  }
  throw new Error('could not derive CA::Render::Update flags offset');
}

function findRejectedPath(prepareAddress, allowedAddress) {
  for (let index = 0; index < 16384; index++) {
    const callAddress = prepareAddress.add(index * 4);
    const target = decodeBLTarget(callAddress);
    if (target === null || !target.equals(allowedAddress)) {
      continue;
    }

    const contextSetup = Instruction.parse(callAddress.sub(12)).toString();
    const updateSetup = Instruction.parse(callAddress.sub(8)).toString();
    const layerSetup = Instruction.parse(callAddress.sub(4)).toString();
    const contextBaseRegister = parseRegister(
      contextSetup,
      /^ldr x1, \[(x\d+), #0x18\]$/i,
      'Context setup register',
    );
    const updateRegister = parseRegister(updateSetup, /^mov x0, (x\d+)$/i, 'Update register');
    const layerRegister = parseRegister(layerSetup, /^mov x2, (x\d+)$/i, 'Layer register');

    for (let delta = 1; delta <= 4; delta++) {
      const branchAddress = callAddress.add(delta * 4);
      const branchText = Instruction.parse(branchAddress).toString();
      if (!/^tbnz w0, #0, /i.test(branchText) && !/^cbnz w0, /i.test(branchText)) {
        continue;
      }
      const rejectedAddress = branchAddress.add(4);
      const rejectedText = Instruction.parse(rejectedAddress).toString();
      if (!/^str xzr, \[x\d+, #0x[0-9a-f]+\]$/i.test(rejectedText) && rejectedText !== 'nop') {
        continue;
      }
      return {
        callAddress,
        rejectedAddress,
        rejectedText,
        contextBaseRegister,
        updateRegister,
        layerRegister,
      };
    }
  }
  throw new Error('could not locate allowed_in_update rejected path');
}

const allowed = findSymbol(allowedSymbols, ios17Offsets.allowed);
const prepare = findSymbol(prepareSymbols, ios17Offsets.prepare);
const processID = findSymbol([processIDSymbol], ios17Offsets.processID);
if (allowed === null || prepare === null || processID === null) {
  throw new Error(`missing symbols allowed=${allowed} prepare=${prepare} processID=${processID}`);
}

const pidOffset = findContextPIDOffset(processID.address);
const layerFlagsOffset = findLayerFlagsOffset(allowed.address);
const updateFlagsOffset = findUpdateFlagsOffset(allowed.address);
const rejected = findRejectedPath(prepare.address, allowed.address);
const sampleCapacity = 32768;
const sampleRecordSize = 176;
const sampleCount = Memory.alloc(4);
const sampleRecords = Memory.alloc(sampleCapacity * sampleRecordSize);
sampleCount.writeU32(0);
const samples = new Map();
let sampleCursor = 0;

console.log(JSON.stringify({
  event: 'ready',
  allowed: allowed.address.toString(),
  prepare: prepare.address.toString(),
  rejected: rejected.rejectedAddress.toString(),
  rejectedInstruction: rejected.rejectedText,
  contextPIDOffset: `0x${pidOffset.toString(16)}`,
  layerFlagsOffset: `0x${layerFlagsOffset.toString(16)}`,
  updateFlagsOffset: `0x${updateFlagsOffset.toString(16)}`,
  contextBaseRegister: rejected.contextBaseRegister,
  updateRegister: rejected.updateRegister,
  layerRegister: rejected.layerRegister,
}));

const callbacks = new CModule(`
  #include <gum/guminterceptor.h>
  #include <stdint.h>

  #define SAMPLE_CAPACITY ${sampleCapacity}
  #define SAMPLE_RECORD_SIZE ${sampleRecordSize}
  #define PID_OFFSET ${pidOffset}
  #define LAYER_FLAGS_OFFSET ${layerFlagsOffset}
  #define UPDATE_FLAGS_OFFSET ${updateFlagsOffset}

  extern volatile guint32 sample_count[];
  extern volatile guint8 sample_records[];

  typedef struct {
    gpointer update;
    gpointer context;
    gpointer layer;
  } InvocationData;

  void onEnter(GumInvocationContext *ic) {
    InvocationData *data = gum_invocation_context_get_listener_invocation_data(
      ic, sizeof(InvocationData));
    data->update = gum_invocation_context_get_nth_argument(ic, 0);
    data->context = gum_invocation_context_get_nth_argument(ic, 1);
    data->layer = gum_invocation_context_get_nth_argument(ic, 2);
  }

  void onLeave(GumInvocationContext *ic) {
    if ((uintptr_t)gum_invocation_context_get_return_value(ic) != 0)
      return;

    InvocationData *data = gum_invocation_context_get_listener_invocation_data(
      ic, sizeof(InvocationData));
    if (data->update == NULL || data->context == NULL || data->layer == NULL)
      return;

    guint32 index = (guint32)g_atomic_int_add((volatile gint *)sample_count, 1);
    if (index >= SAMPLE_CAPACITY)
      return;

    volatile guint8 *record = sample_records + index * SAMPLE_RECORD_SIZE;
    guint32 layer_flags = *(volatile guint32 *)((guint8 *)data->layer + LAYER_FLAGS_OFFSET);
    gpointer ext = *(gpointer *)((guint8 *)data->layer + 0x80);
    gpointer subclass = ext != NULL ? *(gpointer *)ext : NULL;

    *(volatile guint32 *)(record + 4) = *(volatile guint32 *)((guint8 *)data->context + PID_OFFSET);
    *(volatile guint32 *)(record + 8) = (layer_flags >> 20) & 0xff;
    *(volatile guint32 *)(record + 12) = layer_flags;
    *(volatile guint32 *)(record + 16) = *(volatile guint32 *)((guint8 *)data->update + UPDATE_FLAGS_OFFSET);
    *(volatile guint32 *)(record + 20) = *(volatile guint32 *)((guint8 *)data->layer + 0x0c);
    *(volatile guint64 *)(record + 24) = (guint64)(uintptr_t)data->layer;
    *(volatile guint64 *)(record + 32) = *(volatile guint64 *)data->layer;
    *(volatile guint64 *)(record + 40) = (guint64)(uintptr_t)subclass;
    *(volatile guint64 *)(record + 48) = subclass != NULL ? *(volatile guint64 *)subclass : 0;
    *(volatile guint64 *)(record + 56) = *(volatile guint64 *)((guint8 *)data->layer + 0x60);
    *(volatile double *)(record + 64) = *(volatile double *)((guint8 *)data->layer + 0x30);
    *(volatile double *)(record + 72) = *(volatile double *)((guint8 *)data->layer + 0x38);
    *(volatile double *)(record + 80) = *(volatile double *)((guint8 *)data->layer + 0x40);
    *(volatile double *)(record + 88) = *(volatile double *)((guint8 *)data->layer + 0x48);
    *(volatile double *)(record + 96) = *(volatile double *)((guint8 *)data->layer + 0x50);
    *(volatile double *)(record + 104) = *(volatile double *)((guint8 *)data->layer + 0x58);
    *(volatile guint64 *)(record + 112) = (guint64)(uintptr_t)ext;
    *(volatile guint32 *)(record + 120) = *(volatile guint32 *)((guint8 *)data->context + 0x0c);
    *(volatile guint32 *)(record + 124) = *(volatile guint32 *)((guint8 *)data->context + 0x10);
    *(volatile guint32 *)(record + 128) = *(volatile guint32 *)((guint8 *)data->context + 0x14);
    *(volatile guint32 *)(record + 132) = *(volatile guint32 *)((guint8 *)data->context + 0x200);
    *(volatile guint32 *)(record + 136) = *(volatile guint32 *)((guint8 *)data->context + 0x238);
    *(volatile guint32 *)(record + 140) = *(volatile guint32 *)((guint8 *)data->context + 0x23c);
    *(volatile guint32 *)(record + 144) = *(volatile guint32 *)((guint8 *)data->context + 0xd8);
    *(volatile guint64 *)(record + 152) = *(volatile guint64 *)((guint8 *)data->context + 0xe8);
    *(volatile guint64 *)(record + 160) = *(volatile guint64 *)data->context;
    g_atomic_int_add((volatile gint *)record, 1);
  }
`, { sample_count: sampleCount, sample_records: sampleRecords });

const listener = Interceptor.attach(allowed.address, callbacks);

function drainSamples() {
  const reserved = Math.min(sampleCount.readU32(), sampleCapacity);
  while (sampleCursor < reserved) {
    const record = sampleRecords.add(sampleCursor * sampleRecordSize);
    if (record.readU32() === 0) {
      break;
    }
    const row = {
      pid: record.add(4).readU32(),
      disableUpdateMask: record.add(8).readU32(),
      layerFlags: record.add(12).readU32(),
      updateFlags: record.add(16).readU32(),
      typeFlags: record.add(20).readU32(),
      layer: record.add(24).readU64().toString(),
      vtable: record.add(32).readU64().toString(),
      subclass: record.add(40).readU64().toString(),
      subclassVtable: record.add(48).readU64().toString(),
      contents: record.add(56).readU64().toString(),
      positionX: record.add(64).readDouble(),
      positionY: record.add(72).readDouble(),
      boundsX: record.add(80).readDouble(),
      boundsY: record.add(88).readDouble(),
      boundsWidth: record.add(96).readDouble(),
      boundsHeight: record.add(104).readDouble(),
      ext: record.add(112).readU64().toString(),
      contextTypeFlags: record.add(120).readU32(),
      contextID: record.add(124).readU32(),
      contextFlags: record.add(128).readU32(),
      contextSecurityFlags: record.add(132).readU32(),
      contextDisplayMask: record.add(136).readU32(),
      contextDisplayID: record.add(140).readU32(),
      contextPort: record.add(144).readU32(),
      contextRootLayerID: record.add(152).readU64().toString(),
      contextVtable: record.add(160).readU64().toString(),
    };
    const key = JSON.stringify(row);
    const existing = samples.get(key);
    if (existing === undefined) {
      samples.set(key, { row, count: 1 });
    } else {
      existing.count++;
    }
    sampleCursor++;
  }
}

function printSummary(event) {
  drainSamples();
  const rows = [];
  for (const { row, count } of samples.values()) {
    rows.push({
      ...row,
      disableUpdateMask: `0x${row.disableUpdateMask.toString(16)}`,
      layerFlags: `0x${row.layerFlags.toString(16)}`,
      updateFlags: `0x${row.updateFlags.toString(16)}`,
      typeFlags: `0x${row.typeFlags.toString(16)}`,
      contextTypeFlags: `0x${row.contextTypeFlags.toString(16)}`,
      contextFlags: `0x${row.contextFlags.toString(16)}`,
      contextSecurityFlags: `0x${row.contextSecurityFlags.toString(16)}`,
      contextDisplayMask: `0x${row.contextDisplayMask.toString(16)}`,
      contextDisplayID: `0x${row.contextDisplayID.toString(16)}`,
      count,
    });
  }
  rows.sort((left, right) => right.count - left.count);
  console.log(JSON.stringify({
    event,
    total: sampleCount.readU32(),
    retained: sampleCursor,
    rows: rows.slice(0, 64),
  }));
}

const summaryTimer = setInterval(() => printSummary('summary'), 5000);
setTimeout(() => {
  clearInterval(summaryTimer);
  listener.detach();
  printSummary('done');
  send({ event: 'done' });
}, 20000);
