import assert from 'node:assert/strict';
import test from 'node:test';
import {emptyGrain,harvestCropTotals} from '../lib/cometa-grain.ts';

test('crop summaries distinguish harvested totals from current stock across origins and storage sites',()=>{
 const data={...emptyGrain,harvests:[{id:'m1',crop:'Maíz',tonnes:100,voided:false},{id:'m2',crop:'  MAIZ ',tonnes:50,voided:false},{id:'s',crop:'SoJa',tonnes:200,voided:false},{id:'t',crop:'Trigo',tonnes:80.125,voided:false},{id:'void',crop:'Maíz',tonnes:500,voided:true},{id:'other',crop:'Girasol',tonnes:7,voided:false}],balances:[{harvest_id:'m1',store_id:'silo',tonnes:40},{harvest_id:'m1',store_id:'bag',tonnes:20},{harvest_id:'s',store_id:'silo',tonnes:100},{harvest_id:'s',store_id:'bag',tonnes:20},{harvest_id:'t',store_id:'silo',tonnes:0.125},{harvest_id:'t',store_id:'bag',tonnes:0.2},{harvest_id:'void',store_id:'silo',tonnes:500},{harvest_id:'missing',store_id:'silo',tonnes:4},{harvest_id:'other',store_id:'bag',tonnes:7}]};
 const original=JSON.stringify(data);
 assert.deepEqual(harvestCropTotals(data),[{key:'maiz',name:'Maíz',harvested:150,stored:60},{key:'soja',name:'Soja',harvested:200,stored:120},{key:'trigo',name:'Trigo',harvested:80.125,stored:0.325}]);
 assert.equal(JSON.stringify(data),original);
});
test('empty or voided crops show zero and emptying stock does not reduce the harvested quantity',()=>{
 assert.ok(harvestCropTotals(emptyGrain).every(row=>row.harvested===0&&row.stored===0));
 const result=harvestCropTotals({...emptyGrain,harvests:[{id:'m',crop:'Maíz',tonnes:12.5,voided:false},{id:'t',crop:'Trigo',tonnes:10,voided:true}]});
 assert.equal(result[0].harvested,12.5);assert.equal(result[0].stored,0);assert.equal(result[2].harvested,0);
});
