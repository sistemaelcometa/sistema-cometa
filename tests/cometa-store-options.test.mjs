import assert from 'node:assert/strict';
import test from 'node:test';
import {emptyGrain,grainStoreSummary,storeOptionLabel,storeStockDescription} from '../lib/cometa-grain.ts';

test('storage choices show current crops and free space across lots, without changing recorded quantities',()=>{
 const store={id:'silo',kind:'silo',name:'Silo Norte',location:'Casa',capacity:100};
 const data={...emptyGrain,stores:[store],harvests:[{id:'a',crop:'Maíz',voided:false},{id:'b',crop:' MAIZ ',voided:false},{id:'s',crop:'Soja',voided:false},{id:'v',crop:'Trigo',voided:true}],balances:[{store_id:'silo',harvest_id:'a',tonnes:20.125},{store_id:'silo',harvest_id:'b',tonnes:4.875},{store_id:'silo',harvest_id:'s',tonnes:10},{store_id:'silo',harvest_id:'v',tonnes:30},{store_id:'other',harvest_id:'s',tonnes:12}]};
 const before=JSON.stringify(data);
 assert.deepEqual(grainStoreSummary(store,data),{total:35,crops:[{name:'Maíz',tonnes:25},{name:'Soja',tonnes:10}],free:65,excess:0});
 assert.equal(storeOptionLabel(store,data),'Casa · Silo Norte — Maíz: 25 t · Soja: 10 t · Libre: 65 t');
 data.balances[0].tonnes-=5;assert.equal(grainStoreSummary(store,data).free,70);data.balances[0].tonnes+=5;
 assert.equal(JSON.stringify(data),before);
});

test('empty stores, unknown capacity and bags avoid inventing available space',()=>{
 const fixed={id:'empty',kind:'silo',name:'Sur',location:'Casa',capacity:null};
 assert.equal(storeStockDescription(fixed,emptyGrain),'Sin existencias · 0 t · Capacidad sin definir');
 assert.equal(storeStockDescription({...fixed,capacity:150},emptyGrain),'Sin existencias · 0 t · Libre: 150 t');
 const bag={id:'bag',kind:'bag',name:'Bolsa 1',location:'Casa',capacity:200,bag_number:3};
 const data={...emptyGrain,harvests:[{id:'t',crop:'Trigo',voided:false}],balances:[{store_id:'bag',harvest_id:'t',tonnes:25}]};
 assert.equal(storeOptionLabel(bag,data),'Casa · Bolsa 1 · SB-0003 — Trigo: 25 t');
 assert.equal(grainStoreSummary(bag,data).free,null);
 const overloaded={...bag,kind:'silo',capacity:20};assert.equal(storeStockDescription(overloaded,data),'Trigo: 25 t · Exceso de capacidad: 5 t');
});
