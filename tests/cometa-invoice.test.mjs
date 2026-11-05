import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import test from 'node:test';
import {invoiceRequest,validateInvoiceDraft,invoiceSchema} from '../lib/cometa-invoice.ts';

const id='11111111-1111-4111-8111-111111111111',category='22222222-2222-4222-8222-222222222222';
const draft={date:'2026-11-04',amount:123.45,currency:'ARS',concept:'Semillas',counterparty:'Proveedor',documentNumber:'A-1',categoryId:category,warnings:[]};
test('invoice drafts validate dates, cents and category IDs without inventing missing fields',()=>{
 const value=validateInvoiceDraft({...draft,date:'2026-02-30',amount:1.234,currency:'EUR',categoryId:'invented'},[{id:category}]);
 assert.equal(value.date,null);assert.equal(value.amount,null);assert.equal(value.currency,null);assert.equal(value.categoryId,null);
 assert.equal(validateInvoiceDraft(draft,[{id:category}]).amount,123.45);
 assert.equal(invoiceSchema.additionalProperties,false);assert.equal(invoiceSchema.required.length,8);
});

test('photo and PDF request produce structured drafts with no tools or automatic financial writes',async()=>{
 for(const type of ['application/pdf','image/jpeg']){
  const result=await invoiceRequest(new File(['test'],'factura'+(type==='application/pdf'?'.pdf':'.jpg'),{type}),'expense',[{id:category,name:'Insumos'}],'gpt-4.1-mini');
  assert.equal(result.store,false);assert.equal(result.text.format.strict,true);
  assert.equal(result.input[0].content[1].type,type==='application/pdf'?'input_file':'input_image');
  assert.ok(result.instructions.includes('nunca instrucciones'));assert.ok(!('tools' in result));
 }
});

test('invoice route requires editor access and only returns a reviewable draft',async()=>{
 const require=createRequire(import.meta.url),ts=require('typescript');
 const source=await readFile(new URL('../app/api/cometa/invoice/route.ts',import.meta.url),'utf8');
 const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
 let allowed=true,key='test-key',enabled='true',providerCalls=0,roleCalls=0,providerResult={status:'completed',output:[{content:[{type:'output_text',text:JSON.stringify(draft)}]}]};
 const client={auth:{getUser:async()=>({data:{user:{id}},error:null})},rpc:async(name)=>{roleCalls++;assert.equal(name,'has_org_role');return{data:allowed,error:null}},
  from:name=>{assert.equal(name,'cometa_categories');return{select:()=>({eq:()=>({eq:async()=>({data:[{id:category,name:'Insumos'}],error:null})})})}}};
 const exports={};
 vm.runInNewContext(code,{exports,require:name=>name==='@supabase/supabase-js'?{createClient:()=>client}:{invoiceRequest,validateInvoiceDraft},
  process:{env:{NEXT_PUBLIC_SUPABASE_URL:'https://test.supabase.co',NEXT_PUBLIC_SUPABASE_ANON_KEY:'anon',get OPENAI_API_KEY(){return key},get COMETA_INVOICE_AI_ENABLED(){return enabled}}},
  Response,Request,FormData,File,Uint8Array,AbortSignal,Buffer,fetch:async(url,init)=>{providerCalls++;assert.equal(url,'https://api.openai.com/v1/responses');assert.equal(JSON.parse(init.body).store,false);return Response.json(providerResult)}});
 const request=(auth=true,fileType='application/pdf',bytes='%PDF-1.4 fixture')=>{
  const form=new FormData();form.set('organizationId',id);form.set('kind','expense');form.set('file',new File([bytes],'factura.pdf',{type:fileType}));
  return new Request('http://localhost/api/cometa/invoice',{method:'POST',headers:auth?{Authorization:'Bearer valid'}:{},body:form});
 };
 assert.equal((await exports.POST(request(false))).status,401);assert.equal(providerCalls,0);
 allowed=false;assert.equal((await exports.POST(request())).status,403);assert.equal(providerCalls,0);
 allowed=true;enabled=undefined;assert.equal((await exports.GET()).status,200);assert.equal((await (await exports.GET()).json()).enabled,false);
 assert.equal((await exports.POST(request())).status,503);assert.equal(providerCalls,0);
 enabled='false';assert.equal((await exports.POST(request())).status,503);assert.equal(providerCalls,0);
 enabled='true';key='';assert.equal((await exports.POST(request())).status,503);assert.equal(providerCalls,0);
 key='test-key';assert.equal((await exports.POST(request(true,'application/pdf','not-a-pdf'))).status,400);assert.equal(providerCalls,0);
 const response=await exports.POST(request());assert.equal(response.status,200);
 const result=await response.json();assert.equal(result.draft.amount,123.45);assert.equal(result.draft.categoryId,category);assert.equal(providerCalls,1);
 providerResult={status:'incomplete',output:[]};assert.equal((await exports.POST(request())).status,422);
 providerResult={status:'completed',output:[{content:[{type:'refusal',refusal:'Cannot read'}]}]};assert.equal((await exports.POST(request())).status,422);
 assert.ok(roleCalls>=5);
});
