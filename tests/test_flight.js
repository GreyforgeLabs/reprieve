#!/usr/bin/env node
// Actual Flight.qml lifecycle methods; only the Qt destruction/scheduler
// boundary is stubbed. Scene rendering is covered by the live motion captures.
'use strict'
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const source = fs.readFileSync(require.resolve('../Flight.qml'), 'utf8')
let destroyed = 0
const deferred = []
const root = {service: {undoStack: [], redoStack: []}, scenes: {f1: {job: {address: '0xabc'}}},
  memory: {'0xabc': {view: {destroy() {destroyed++}}}}, activeCount: 1, flown: 0}
const context = vm.createContext({root, Qt: {callLater: fn => deferred.push(fn)}})
for (const method of source.matchAll(/^  function (\w+)\([^\n]*\) \{\n[\s\S]*?^  \}/gm)) {
  vm.runInContext(method[0], context); root[method[1]] = context[method[1]]
}
root.prune()
assert.equal(destroyed, 0, 'pruning history destroyed the frame of a running flight')
root.sceneDone({job: {token: 'f1', address: '0xabc'}, destroy() {}})
for (const fn of deferred) fn()
assert.equal(destroyed, 1, 'a completed flight retained a frame with no history owner')
assert.equal(Object.keys(root.memory).length, 0)
console.log('PASS active snapshot survives pruning and is released after landing')
// Evaluate the actual scene expressions across the lift/carry handoff.
const scene = vm.createContext({scene: {width: 2560}, rect: {x: 300, y: 250, w: 600, h: 400},
  cx: 600, cy: 450, ax: 2184, ay: 18, hoverPx: 20, liftPx: 10, minScale: .05,
  t: .42, angel: true, park: true, cutDone: false, Math})
for (const method of source.matchAll(/^      function (\w+)\([^\n]*\) \{[^\n]*\}/gm)) vm.runInContext(method[0], scene)
for (const method of source.matchAll(/^      function (\w+)\([^\n]*\) \{\n[\s\S]*?^      \}/gm)) vm.runInContext(method[0], scene)
for (const property of ['snap', 'wing']) {
  const expression = source.match(new RegExp('      readonly property var ' + property + ': \\{([\\s\\S]*?)^      \\}', 'm'))[1]
  vm.runInContext('function compute_' + property + '() {' + expression + '}', scene)
}
for (const time of [.359, .36, .42, .499, .5]) {
  scene.t = time; scene.snap = scene.compute_snap()
  assert.ok(scene.compute_wing().o > .9, `angel vanished during lift at t=${time}`)
}
console.log('PASS angel stays visible across the lift/carry handoff')
