import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const require=createRequire(import.meta.url),ts=require('typescript');
const source=await readFile(new URL('../app/page.tsx',import.meta.url),'utf8');
const ast=ts.createSourceFile('page.tsx',source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const functions=new Map();
function visit(node){if(ts.isFunctionDeclaration(node))functions.set(node.name?.text,node);ts.forEachChild(node,visit)}visit(ast);

test('history loader groups expired and current leases independently of department occupancy',async()=>{
  let history,options;
  const load=vm.runInNewContext(`${functions.get('loadUrbanLeaseHistory').getText(ast)};loadUrbanLeaseHistory`,{
    activeMembership:{organization_id:'org'},
    argentinaDay:()=> '2026-11-02',
    resourceCacheKey:(type,params)=>{assert.equal(type,'urbanLeaseHistory');assert.equal(params.organizationId,'org');return 'key'},
    resourceCache:{async hydrate(key,fetch,opts){options=opts;return{data:await fetch()}}},
    supabase:{async rpc(name,args){assert.equal(name,'get_urban_lease_history');assert.equal(args.target_organization_id,'org');return{data:[
      {id:'old',unit_id:'available-unit',tenant_name:'Anterior',status:'Finalizado',start_date:'2024-11-01',end_date:'2026-10-31',amount:550000,currency:'ARS'},
      {id:'new',unit_id:'rented-unit',tenant_name:'Actual',status:'Activo',amount:100,currency:'USD'},
      {id:'older',unit_id:'rented-unit',tenant_name:'Otro',status:'Finalizado',amount:90,currency:'USD'},
    ],error:null}}},
    formatCurrency:(amount,currency)=>currency+' '+amount,v:value=>{history=value},
  });
  await load(true);
  assert.equal(options.force,true);
  assert.equal(history['available-unit'][0].tenantName,'Anterior');
  assert.equal(history['available-unit'][0].endDate,'2026-10-31');
  assert.equal(history['available-unit'][0].amount,'ARS 550000');
  assert.equal(history['rented-unit'].length,2);
});

test('failed history refresh preserves loaded history and reports the SQL error',async()=>{
  let updated=false;
  const load=vm.runInNewContext(`${functions.get('loadUrbanLeaseHistory').getText(ast)};loadUrbanLeaseHistory`,{
    activeMembership:{organization_id:'org'},argentinaDay:()=> '2026-11-02',resourceCacheKey:()=> 'key',
    resourceCache:{async hydrate(key,fetch){return{data:await fetch()}}},
    supabase:{async rpc(){return{error:new Error('Error SQL')}}},v:()=>{updated=true},
  });
  await assert.rejects(load(),/Error SQL/);assert.equal(updated,false);
  const structure=functions.get('loadUrbanStructureLite').getText(ast);
  assert.ok(structure.includes('await loadUrbanLeaseHistory(force)'));
  assert.ok(!structure.includes('v(a)'));
});
