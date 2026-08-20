'use strict';

if (!ObjC.available) {
  throw new Error('Objective-C runtime unavailable');
}

function describe(shell) {
  if (!shell) return null;
  return {
    className: shell.$className,
    bundleIdentifier: shell.bundleIdentifier().toString(),
    pid: Number(shell.pid()),
  };
}

const ProbeObserver = ObjC.registerClass({
  name: 'UnseenSystemShellObserverProbe',
  super: ObjC.classes.NSObject,
  protocols: [ObjC.protocols.BKSystemShellObserver],
  methods: {
    '- systemShellWillBootstrap': function () {
      console.log(JSON.stringify({ event: 'will-bootstrap' }));
    },
    '- systemShellDidFinishLaunching:': function (shell) {
      console.log(JSON.stringify({ event: 'did-finish-launching', shell: describe(shell) }));
    },
    '- systemShellChangedWithPrimary:': function (shell) {
      console.log(JSON.stringify({ event: 'primary-changed', shell: describe(shell) }));
    },
  },
});

const observer = ProbeObserver.alloc().init();
const sentinel = ObjC.classes.BKSystemShellSentinel.sharedInstance();
const registration = sentinel.addSystemShellObserver_reason_(observer, 'Unseen lifecycle probe');
const shells = sentinel.systemShells();
const shellDescriptions = [];
for (let i = 0; i < Number(shells.count()); i++) {
  shellDescriptions.push(describe(shells.objectAtIndex_(i)));
}

console.log(JSON.stringify({
  event: 'ready',
  registration: registration.toString(),
  primary: describe(sentinel.primarySystemShell()),
  shells: shellDescriptions,
}));

setInterval(function () {}, 1000);
