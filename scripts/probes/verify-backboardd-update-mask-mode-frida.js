/*
 * Read-only verification of Unseen's update-mask mode on iOS 17.0.
 *
 * Process-aware ON:
 *   - allowed_in_update entry is hooked
 *   - prepare_layer0 clear-store remains intact
 * Original path (switch OFF):
 *   - allowed_in_update entry remains intact
 *   - prepare_layer0 clear-store is NOP
 */

'use strict';

const quartzCore = Process.getModuleByName('QuartzCore');
const unseen = Process.getModuleByName('Unseen.dylib');
const ios17Offsets = {
  allowed: 0x292d4,
  prepare: 0x1c9a8,
};

function resolveQuartzCoreSymbol(names, fallbackOffset) {
  for (const name of names) {
    let address = null;
    try {
      address = quartzCore.findExportByName(name);
    } catch (_) {
      address = null;
    }
    if (address !== null && !address.isNull()) return address;
  }
  return quartzCore.base.add(fallbackOffset);
}

function decodeBLTarget(address) {
  const raw = address.readU32() >>> 0;
  if (((raw & 0xfc000000) >>> 0) !== 0x94000000) return null;
  let immediate = raw & 0x03ffffff;
  if ((immediate & 0x02000000) !== 0) immediate -= 0x04000000;
  return address.add(immediate * 4);
}

function findClearStore(prepare, allowed) {
  for (let index = 0; index < 16384; index++) {
    const call = prepare.add(index * 4);
    const target = decodeBLTarget(call);
    if (target === null || !target.equals(allowed)) continue;
    for (let delta = 1; delta <= 4; delta++) {
      const branch = call.add(delta * 4);
      const branchText = Instruction.parse(branch).toString();
      if (!/^tbnz w0, #0, /i.test(branchText) && !/^cbnz w0, /i.test(branchText)) continue;
      for (let storeDelta = delta + 1; storeDelta <= delta + 3; storeDelta++) {
        const store = call.add(storeDelta * 4);
        const storeText = Instruction.parse(store).toString();
        if (/^str xzr, \[x\d+, #0x[0-9a-f]+\]$/i.test(storeText) || storeText === 'nop') {
          return { call, store, storeText };
        }
      }
    }
  }
  throw new Error('prepare_layer0 clear-store not found');
}

function readExportedBool(name) {
  const address = unseen.findExportByName(name);
  if (address === null || address.isNull()) throw new Error(`missing ${name}`);
  return address.readU8() !== 0;
}

const allowed = resolveQuartzCoreSymbol([
  '__ZNK2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE',
  '__ZN2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE',
], ios17Offsets.allowed);
const prepare = resolveQuartzCoreSymbol([
  '__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPNS0_5LayerERNS1_11LocalState0Ey',
  '__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPKNS0_5LayerERNS1_11LocalState0Ey',
], ios17Offsets.prepare);
const clearStore = findClearStore(prepare, allowed);

const sentinel = ObjC.classes.BKSystemShellSentinel.sharedInstance();
const primary = sentinel.primarySystemShell();
console.log(JSON.stringify({
  processAwarePreference: readExportedBool('gUnseenProcessAwareUpdateMaskBypassEnabled'),
  revealPreference: readExportedBool('gUnseenDisableUpdateMaskPatchEnabled'),
  allowedEntry: {
    address: allowed.toString(),
    instruction: Instruction.parse(allowed).toString(),
  },
  prepareCall: clearStore.call.toString(),
  clearStore: {
    address: clearStore.store.toString(),
    instruction: clearStore.storeText,
  },
  primarySystemShell: primary === null ? null : {
    bundleIdentifier: primary.bundleIdentifier().toString(),
    pid: Number(primary.pid()),
  },
}));
