import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const require=createRequire(import.meta.url),ts=require('typescript');
const source=await readFile(new URL('../app/page.tsx',import.meta.url),'utf8');
const ast=ts.createSourceFile('page.tsx',source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const code=['expenseReceiptLines','L','h'].map(name=>ast.statements.find(n=>ts.isFunctionDeclaration(n)&&n.name.text===name).getText(ast)).join('\n');
export const calculation={
 buildingName:'PELLEGRINI',period:'Octubre 2026',dueDates:['10/11/2026','20/11/2026','21/11/2026'],
 expenses:[
  {id:'common',group:'Servicios',category:'Agua',amount:400},
  {id:'excluded',group:'Mantenimiento',category:'Reparacion excluida',amount:400,excludedUnitIds:['studio']},
 ],
 units:['one','two','three','four','studio'].map(unitId=>({unitId,unitName:unitId==='studio'?'ESTUDIO':unitId,surface:20,percentage:0.2,tenant:'Inquilino',address:'Pellegrini 571',currency:'ARS',rentAmount:1000,baseAmount:unitId==='studio'?80:180,secondAmount:unitId==='studio'?88:198,thirdAmount:unitId==='studio'?96.8:217.8})),
};

export function receiptContext(){
 let blob,download;
 const context=vm.createContext({Blob,Uint8Array,URL:{createObjectURL:value=>{blob=value;return 'blob:test'},revokeObjectURL(){}},document:{createElement:()=>({set download(value){download=value},click(){}})}});
 vm.runInContext(code,context);
 return {context,get blob(){return blob},get download(){return download}};
}

test('receipts omit excluded costs and distribute each cost over its own included surface',()=>{
 const {context}=receiptContext(),lines=calculation.units.map(unit=>context.expenseReceiptLines(calculation,unit));
 assert.equal(lines[4].length,1);assert.equal(lines[4][0].amount,80);
 assert.equal(lines[0].length,2);assert.equal(lines[0][1].amount,100);
 assert.equal(lines[0].reduce((sum,line)=>sum+line.amount,0),180);
 assert.equal(lines.flat().reduce((sum,line)=>sum+line.amount,0),800);
 const unequal={...calculation,units:[{unitId:'a',surface:60},{unitId:'studio',surface:30},{unitId:'b',surface:10}]};
 assert.equal(context.expenseReceiptLines(unequal,unequal.units[0])[1].amount,400*60/70);
 assert.equal(context.expenseReceiptLines(unequal,unequal.units[2])[1].amount,400*10/70);
});

test('generated PDF excludes the studio cost, includes the correct share for other units and preserves totals',async()=>{
 const original=JSON.stringify(calculation);
 for(const index of [4,0]){
  const result=receiptContext();result.context.L(calculation,calculation.units[index]);
  const text=Buffer.from(await result.blob.arrayBuffer()).toString('latin1');
  assert.ok(text.startsWith('%PDF-'));assert.ok(result.download.endsWith('.pdf'));
  assert.equal(text.includes('Reparacion excluida'),index===0);
  assert.ok(text.includes(index===4?'($ 80,00)':'($ 180,00)'));
  assert.ok(text.includes(index===4?'($ 1.080,00)':'($ 1.180,00)'));
  if(index===0)assert.ok(text.includes('($ 100,00)'));
 }
 assert.equal(JSON.stringify(calculation),original);
});
