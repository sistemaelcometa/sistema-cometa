import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const require=createRequire(import.meta.url),ts=require('typescript');
const source=await readFile(new URL('../app/page.tsx',import.meta.url),'utf8');
const ast=ts.createSourceFile('page.tsx',source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX),functions=new Map();
function visit(node){if(ts.isFunctionDeclaration(node))functions.set(node.name?.text,node);ts.forEachChild(node,visit)}visit(ast);
const top=name=>ast.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name.text===name).getText(ast);

test('miscellaneous income save carries the operation key, refreshes PDE caches and keeps a saved receipt warning distinct from a failed save',async()=>{
  const requests=[],stale=[],loads=[];
  const save=vm.runInNewContext(`${functions.get('savePdeMiscIncome').getText(ast)};savePdeMiscIncome`,{
    activeMembership:{organization_id:'org'},supabase:{async rpc(name,args){requests.push({name,args});return{data:{id:'income'},error:null}}},
    setUrbanSyncing(){},uploadReceiptForEntity:async()=> 'Comprobante no se pudo subir',
    resourceCache:{markStale:key=>stale.push(key)},loadPdeData:async force=>loads.push(force),
  });
  const result=await save({date:'2026-10-29',amount:12.34,detail:'Reintegro',unit:'General',method:'cash',operationId:'operation'});
  assert.equal(requests[0].name,'register_pde_misc_income');assert.equal(requests[0].args.operation_id,'operation');
  assert.equal(requests[0].args.income_amount,12.34);assert.equal(requests[0].args.target_unit_name,null);
  assert.match(result.warning,/Ingreso registrado/);assert.deepEqual(stale,['pdeData:','pdeReport:']);assert.deepEqual(loads,[true]);
});

test('income cancellation removes its local row before reload but never removes it on RPC failure',async()=>{
  for(const failed of [false,true]){
    let rows=[{id:'one'},{id:'two'}],release,loading=false;
    const remove=vm.runInNewContext(`${functions.get('deletePdeMiscIncome').getText(ast)};deletePdeMiscIncome`,{
      activeMembership:{organization_id:'org'},supabase:{async rpc(){return{error:failed?{message:'Error de prueba'}:null}}},
      setUrbanSyncing(){},setPdeMiscIncomes:update=>{rows=update(rows)},resourceCache:{markStale(){}},
      loadPdeData:async()=>{loading=true;await new Promise(resolve=>{release=resolve})},
    });
    const pending=remove('one');await new Promise(resolve=>setImmediate(resolve));
    assert.deepEqual(rows.map(row=>row.id),failed?['one','two']:['two']);
    assert.equal(loading,!failed);release?.();assert.equal(await pending,failed?'Error de prueba':true);
  }
});

test('PDE balance and report fallback include miscellaneous incomes once without classifying them as rent',()=>{
  const calendar=functions.get('V'),reports=functions.get('PdeReports');
  const declarations=node=>node.body.statements.filter(ts.isVariableStatement).flatMap(statement=>Array.from(statement.declarationList.declarations));
  const balance=declarations(calendar).find(item=>item.name.getText(ast)==='cashBalance');
  assert.equal(vm.runInNewContext(balance.initializer.getText(ast),{totalPaid:100,totalExpenses:20.01,miscIncomes:[{amount:50.25}]}),130.24);
  const fallback=declarations(reports).find(item=>item.name.getText(ast)==='fallbackRows');
  const rows=vm.runInNewContext(`${top('h')}\n${top('_')}\n${fallback.initializer.getText(ast)}`,{
    reservations:[],expenses:[],miscIncomes:[{id:'income',unit:'General',date:'2026-10-29',amount:50.25,detail:'Reintegro',method:'cash'}],
  });
  assert.equal(rows.length,1);assert.equal(rows[0].sourceType,'pde_misc_income');assert.equal(rows[0].amount,50.25);assert.equal(rows[0].concept,'Ingresos varios');
  const chart=declarations(reports).find(item=>item.name.getText(ast)==='chartData');
  const data=vm.runInNewContext(chart.initializer.getText(ast),{remoteReport:null,localPeriodRows:rows,outcomes:0});
  assert.equal(data.rentIncome,0);assert.equal(data.expenseIncome,50.25);
  assert.ok(calendar.getText(ast).includes('>Historial de gastos</button><button className="secondary-button compact-action" type="button" onClick={()=>setShowMiscIncomes(true)}>Ingresos varios</button>'));
});
