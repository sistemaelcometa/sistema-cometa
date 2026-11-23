import assert from 'node:assert/strict';
import test from 'node:test';
import {emptyGrain,harvestCropTotals,storageCropTotals} from '../lib/cometa-grain.ts';

test('storage by crop splits current stock between fixed silos and bags across lots',()=>{
 const data={...emptyGrain,stores:[{id:'fixed',kind:'silo'},{id:'bag',kind:'bag'}],harvests:[{id:'m1',crop:'Maíz',tonnes:100,voided:false},{id:'m2',crop:' MAIZ ',tonnes:50,voided:false},{id:'s',crop:'Soja',tonnes:200,voided:false},{id:'t',crop:'Trigo',tonnes:0.5,voided:false},{id:'v',crop:'Trigo',tonnes:99,voided:true}],balances:[{harvest_id:'m1',store_id:'fixed',tonnes:40},{harvest_id:'m1',store_id:'bag',tonnes:20},{harvest_id:'m2',store_id:'bag',tonnes:10},{harvest_id:'s',store_id:'fixed',tonnes:100},{harvest_id:'s',store_id:'bag',tonnes:20},{harvest_id:'t',store_id:'fixed',tonnes:0.125},{harvest_id:'t',store_id:'bag',tonnes:0.2},{harvest_id:'v',store_id:'bag',tonnes:99},{harvest_id:'missing',store_id:'bag',tonnes:50}]};
 const original=JSON.stringify(data),before=harvestCropTotals(data);
 assert.deepEqual(storageCropTotals(data),[{key:'maiz',name:'Maíz',stored:70,fixed:40,bags:30},{key:'soja',name:'Soja',stored:120,fixed:100,bags:20},{key:'trigo',name:'Trigo',stored:0.325,fixed:0.125,bags:0.2}]);
 assert.deepEqual(harvestCropTotals(data),before);assert.equal(JSON.stringify(data),original);
});
test('a transfer changes the location split without changing total stored or harvested',()=>{
 const data={...emptyGrain,stores:[{id:'fixed',kind:'silo'},{id:'bag',kind:'bag'}],harvests:[{id:'m',crop:'Maíz',tonnes:100,voided:false}],balances:[{harvest_id:'m',store_id:'fixed',tonnes:40},{harvest_id:'m',store_id:'bag',tonnes:60}]};
 const initial=storageCropTotals(data)[0];data.balances[0].tonnes+=10;data.balances[1].tonnes-=10;const moved=storageCropTotals(data)[0];assert.equal(initial.stored,moved.stored);assert.equal(moved.fixed,50);assert.equal(moved.bags,50);
 assert.equal(harvestCropTotals(data)[0].harvested,100);assert.ok(storageCropTotals(emptyGrain).every(row=>row.stored===0&&row.fixed===0&&row.bags===0));
});
