import assert from 'node:assert/strict';
import test from 'node:test';
import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { parsePdeExpenseAmount, formatPdeExpenseInput, splitPdeExpenseAmount } from '../lib/pde-expense-amounts.ts';

test('PDE expense accepts comma or dot cents and retains existing whole-peso grouping', () => {
  for (const [input,expected] of [['1500,25',1500.25],['1.500,25',1500.25],['1500.25',1500.25],['1,500.25',1500.25],['1.500',1500],['1500',1500],['0,01',0.01],['.25',0.25],[',50',0.5],[' 123,4 ',123.4],['123,',123],['999.999.999.999,99',999999999999.99]]) {
    assert.equal(parsePdeExpenseAmount(input),expected,input);
  }
  assert.equal(formatPdeExpenseInput(1500.25),'1.500,25');
  assert.equal(formatPdeExpenseInput(0.01),'0,01');
});

test('PDE expense rejects missing, negative, malformed or excessive precision/amounts', () => {
  for(const input of ['', '0', '0,00', '-12,50', '12,345', '12,3,4', '1.23,45', '0.005', '10000.123', 'USD 12,50', '1e3', 'NaN', 'Infinity', '1000000000000,00']) {
    assert.equal(parsePdeExpenseAmount(input),null,input);
  }
});

test('general expenses keep every cent and match the database rounding rule', () => {
  for(const [amount,expected] of [[100.01,[50.01,50]],[0.01,[0.01,0]],[1500.25,[750.13,750.12]],[100,[50,50]],[0.29,[0.15,0.14]]]) {
    const result=splitPdeExpenseAmount(amount);
    assert.deepEqual(result,expected);
    assert.equal(result.reduce((sum,item)=>sum+Math.round(item*100),0),Math.round(amount*100));
  }
});

const require=createRequire(import.meta.url),ts=require('typescript');
const source=await readFile(new URL('../app/page.tsx',import.meta.url),'utf8');
const ast=ts.createSourceFile('page.tsx',source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const functions=new Map();
function visit(node){if(ts.isFunctionDeclaration(node))functions.set(node.name?.text,node);ts.forEachChild(node,visit)}visit(ast);
function topLevel(name){return ast.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name.text===name)}
const modal=functions.get('PdeExpenseModal');
const submit=modal.body.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name.text==='submit').getText(ast);

test('actual expense submit preserves decimals, permits correction after errors and never submits invalid money', () => {
  for(const [input,expected] of [['1.500,25',1500.25],['0.01',0.01],['12,345',null],['-1',null]]){
    const saved=[],messages=[];
    const values={amount:input,unit:'General',date:'2026-10-27',rubric:'UTE',detail:'Luz',receipt:null};
    vm.runInNewContext(`${submit};submit({preventDefault(){},currentTarget:{elements:{namedItem(){return input}}}})`,{
      fieldName:name=>name,units:['209','601'],parsePdeExpenseAmount,
      FormData:class{get(key){return values[key]}},
      input:{setCustomValidity(message){messages.push(message)},reportValidity(){}},
      onSave:data=>saved.push(data),
    });
    if(expected===null){assert.equal(saved.length,0);assert.equal(messages.length,1)}
    else{assert.equal(saved.length,1);assert.equal(saved[0].amount,expected)}
  }
  assert.ok(modal.getText(ast).includes('inputMode="decimal"'));
  assert.ok(modal.getText(ast).includes('onInput={event=>event.currentTarget.setCustomValidity(``)}'));
});

test('saving an expense sends exact cents to the RPC and uses a cent-safe local split', async () => {
  const save=functions.get('savePdeExpense').getText(ast),requests=[],local=[];
  let remote=true;
  const saveExpense=vm.runInNewContext(`${save};savePdeExpense`,{
    get activeMembership(){return remote?{organization_id:'org'}:null},
    supabase:{async rpc(name,args){requests.push({name,args});return{data:{id:'expense'},error:null}}},
    setUrbanSyncing(){},pdeOperationId:()=> 'operation',uploadReceiptForEntity:async()=>'',markPdeExpenseCachesStale(){},
    loadPdeData:async()=>{},setPdeExpenses:update=>{local.splice(0,local.length,...update(local))},splitPdeExpenseAmount,
  });
  await saveExpense({amount:1500.25,unit:'601',rubric:'UTE',date:'2026-10-27'});
  assert.equal(requests[0].name,'register_pde_expense');assert.equal(requests[0].args.amount,1500.25);
  remote=false;
  await saveExpense({amount:100.01,unit:'General',rubric:'Limpieza',date:'2026-10-27'});
  assert.deepEqual(local.map(item=>item.amount),[50.01,50]);
});

test('PDE chart shows cents while urban charts keep their existing whole-number format', () => {
  const fn=functions.get('ReportMarginChart');
  const declaration=fn.body.statements.find(node=>ts.isVariableStatement(node)&&node.declarationList.declarations.some(item=>item.name.getText(ast)==='money'));
  assert.ok(declaration);
  for(const showCents of [false,true]){
    const result=vm.runInNewContext(`${topLevel('h').getText(ast)}\n${topLevel('formatCurrency').getText(ast)}\n${declaration.getText(ast)};money(1500.25,'USD')`,{showCents});
    assert.equal(result,showCents?'USD 1.500,25':'USD 1.500');
  }
  assert.ok(functions.get('PdeReports').getText(ast).includes('<ReportMarginChart showCents'));
  assert.ok(functions.get('PdeExpenseHistoryModal').getText(ast).includes('formatPdeExpenseInput(item.amount)'));
  assert.ok(functions.get('V').getText(ast).includes('h(cashBalance,`USD`)'));
});

test('existing PostgreSQL RPC preserves expense cents and the exact general expense allocation sum', async () => {
  const db=new PGlite(),org=randomUUID(),actor=randomUUID();
  function sqlFunction(text,name){const start=text.indexOf(`create or replace function ${name}(`);assert.ok(start>=0,name);return text.slice(start,text.indexOf('$$;',text.indexOf('as $$',start))+3)}
  const query=async(text,args=[])=>(await db.query(text,args)).rows;
  try{
    const schema=await readFile(new URL('../supabase/migrations/001_initial_rentals_schema.sql',import.meta.url),'utf8');
    await db.exec(`create schema auth;create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.actor_id',true),'')::uuid;$$;`);
    await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
    await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
    for(const name of ['has_org_role','is_org_member'])await db.exec(sqlFunction(schema,name));
    const rpc=await readFile(new URL('../supabase/migrations/012_pde_reservations_rpcs.sql',import.meta.url),'utf8');
    for(const name of ['ensure_pde_unit','ensure_pde_category','register_pde_expense','get_pde_data'])await db.exec(sqlFunction(rpc,name));
    await query("select set_config('test.actor_id',$1,false)",[actor]);
    await query('insert into auth.users values($1)',[actor]);
    await query("insert into profiles(id,email) values($1,'test@localhost')",[actor]);
    await query("insert into organizations(id,name,slug) values($1,'Prueba','prueba')",[org]);
    await query("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')",[org,actor]);
    for(const [amount,general] of [[1500.25,false],[100.01,true],[0.01,true]]){
      const operation=randomUUID();
      const params=[org,amount,general?null:'601',general,operation];
      const command="select * from register_pde_expense($1,'UTE','2026-10-27',$2,'Servicio','USD',$3,$4,null,null,$5)";
      const [expense]=await query(command,params);
      assert.equal(Number(expense.amount),amount);
      const allocated=await query('select a.allocated_amount,u.name from pde_expense_allocations a join pde_units u on u.id=a.unit_id where a.expense_id=$1 order by u.name',[expense.id]);
      assert.equal(allocated.reduce((sum,item)=>sum+Math.round(Number(item.allocated_amount)*100),0),Math.round(amount*100));
      if(general)assert.deepEqual(allocated.map(item=>Number(item.allocated_amount)),splitPdeExpenseAmount(amount));
      assert.equal((await query(command,params))[0].id,expense.id);
      const [data]=await query('select get_pde_data($1) as data',[org]);
      const readRows=data.data.expenses.filter(item=>item.expenseId===expense.id);
      assert.equal(readRows.reduce((sum,item)=>sum+Math.round(item.amount*100),0),Math.round(amount*100));
    }
  }finally{await db.close()}
});
