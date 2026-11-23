import assert from 'node:assert/strict';
import test from 'node:test';
import {bagReferenceTonnes} from '../lib/cometa-grain.ts';
let sequence=0;
const event=(destination,amount,source=null,extra={})=>({id:String(++sequence),operation_id:String(sequence),harvest_id:'harvest',event_date:'2026-11-23',kind:source?'transfer':'deposit',source_id:source,destination_id:destination,tonnes:amount,recipient:'',reference:'',voided_at:null,sequence,...extra});

test('each bag uses its own actual fill: 200 and 50 tonnes stay independent after withdrawals',()=>{
 const entries=[event('large',200),event('short',50),event(null,50,'large'),event(null,10,'short')];
 assert.equal(bagReferenceTonnes('large',entries.slice().reverse()),200);assert.equal(bagReferenceTonnes('short',entries.slice().reverse()),50);
 assert.equal(150/bagReferenceTonnes('large',entries)*100,75);assert.equal(40/bagReferenceTonnes('short',entries)*100,80);
 assert.equal(bagReferenceTonnes('empty',entries),0);
});
test('successive fills complete a bag while withdrawals and smaller refills preserve its reference',()=>{
 const entries=[event('bag',50),event('bag',150),event(null,40,'bag'),event('bag',30,'silo')];
 assert.equal(bagReferenceTonnes('bag',entries),200);
 entries.push(event('bag',20));assert.equal(bagReferenceTonnes('bag',entries),210);
 entries.push(event(null,210,'bag'));assert.equal(bagReferenceTonnes('bag',entries),210);
});
test('voided quantities are excluded and an empty unfilled bag has no invented reference',()=>{
 const entries=[event('bag',50),event('bag',200,null,{voided_at:'2026-11-23'}),event(null,20,'bag',{voided_at:'2026-11-23'})];
 assert.equal(bagReferenceTonnes('bag',entries),50);assert.equal(bagReferenceTonnes('bag',entries.map(row=>({...row,voided_at:'2026-11-23'}))),0);
});
test('kilogram precision and chronological order survive reversed API results and backdated entries',()=>{
 const first=event('bag',0.125,null,{event_date:'2026-11-01'}),second=event('bag',0.375,null,{event_date:'2026-11-01'}),sale=event(null,0.2,'bag',{event_date:'2026-11-02'});
 assert.equal(bagReferenceTonnes('bag',[sale,second,first]),0.5);
 assert.equal(bagReferenceTonnes('bag',[sale,second,first].map(({sequence,...row})=>row)),0.5);
 const late=event('bag',1,null,{event_date:'2026-10-31'});assert.equal(bagReferenceTonnes('bag',[sale,second,first,late]),1.5);
});
