import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {receiptZip,crc32,receiptFilename,receiptNumber,receiptIndex,receiptMonthName} from '../lib/cometa-receipts.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('monthly numbers, receipt attachment, frozen exports and confirmed storage cleanup preserve all movements',async()=>{
 const db=new PGlite(),org=randomUUID(),other=randomUUID(),actor=randomUUID(),q=async(sql,args=[])=>(await db.query(sql,args)).rows;
 try{
  const schema=await read('supabase/migrations/001_initial_rentals_schema.sql');
  await db.exec("create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.actor',true),'')::uuid;$$;grant usage on schema auth to authenticated;create schema storage;create table storage.objects(bucket_id text,name text);");
  await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
  for(const name of ['is_org_member','has_org_role'])await db.exec(fn(schema,name));
  await q("select set_config('test.actor',$1,false)",[actor]);await q('insert into auth.users values($1)',[actor]);await q("insert into profiles(id,email) values($1,'test@local')",[actor]);
  await q("insert into organizations(id,name,slug) values($1,'Campo','campo'),($2,'Otro','otro')",[org,other]);
  await q("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')",[org,actor]);
  await db.exec(await read('supabase/migrations/074_cometa_agricultural_movements.sql'));
  const category=(await q("select id from cometa_categories where organization_id=$1 and name='Insumos'",[org]))[0].id;
  const upload=async(operation=randomUUID(),ext='pdf')=>{const path='org/'+org+'/cometa/'+operation+'/receipt.'+ext;await q("insert into storage.objects values('receipts',$1)",[path]);return{path,operation}};
  const save=async(day,file=null)=>(await q("select * from register_cometa_movement($1,'expense',$2,$3,123.45,'ARS','Semillas',null,'A-001',null,$4,$5,$6)",[org,day,category,file?.path||null,file?'factura.pdf':null,file?.operation||randomUUID()]))[0];
  const fileA=await upload(),a=await save('2026-11-01',fileA),b=await save('2026-11-02'),fileC=await upload(),c=await save('2026-11-03',fileC);
  await q('select void_cometa_movement($1,$2)',[org,c.id]);
  const migration=await read('supabase/migrations/075_cometa_receipt_archives.sql');await db.exec(migration);await db.exec(migration);
  assert.deepEqual((await q('select receipt_number from cometa_movements order by movement_date')).map(row=>row.receipt_number),[1,2,3]);
  const fileB=await upload(randomUUID(),'webp');
  await q("select attach_cometa_receipt($1,$2,$3,$4,'foto.webp')",[org,b.id,fileB.operation,fileB.path]);await q("select attach_cometa_receipt($1,$2,$3,$4,'foto.webp')",[org,b.id,fileB.operation,fileB.path]);
  await assert.rejects(q("select attach_cometa_receipt($1,$2,$3,$4,'otro.pdf')",[org,a.id,fileB.operation,fileB.path]),/ya tiene/);
  const december=await save('2026-12-01');assert.equal(december.receipt_number,1);
  const archive=(await q("select * from begin_cometa_receipt_export($1,'2026-11-01')",[org]))[0];
  assert.equal(archive.entries.length,3);assert.ok(archive.entries.some(row=>row.status==='voided'));
  const afterFile=await upload(),after=await save('2026-11-04',afterFile);assert.equal(after.receipt_number,4);
  const finances=await q('select id,kind,movement_date,amount,currency,category_id,concept,document_number,status,receipt_number,receipt_month from cometa_movements order by id');
  const allowed=async path=>(await q('select can_delete_exported_cometa_receipt($1) as allowed',[path]))[0].allowed;
  assert.equal(await allowed(fileA.path),false);
  const manifest=archive.entries.map(row=>({movement_id:row.movement_id,path:row.path,sha256:'a'.repeat(64),bytes:100}));
  await assert.rejects(q('select complete_cometa_receipt_export($1,$2,$3)',[org,archive.id,JSON.stringify(manifest.slice(1))]),/todos/);
  await assert.rejects(q('select complete_cometa_receipt_export($1,$2,$3)',[org,archive.id,JSON.stringify([manifest[0],manifest[0],manifest[2]])]),/indice/);
  await assert.rejects(q('select finish_cometa_receipt_cleanup($1,$2)',[org,archive.id]),/confirmar/);
  await q('select complete_cometa_receipt_export($1,$2,$3)',[org,archive.id,JSON.stringify(manifest)]);
  assert.equal(await allowed(fileA.path),false);
  await assert.rejects(q('select authorize_cometa_receipt_cleanup($1,$2)',[other,archive.id]),/permisos/);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);
  await assert.rejects(q('select authorize_cometa_receipt_cleanup($1,$2)',[org,archive.id]),/permisos/);
  await q("update organization_members set role='owner' where organization_id=$1",[org]);
  await q('select authorize_cometa_receipt_cleanup($1,$2)',[org,archive.id]);
  assert.equal(await allowed(fileA.path),true);assert.equal(await allowed(afterFile.path),false);
  await db.exec("alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select,delete on storage.objects to authenticated;create policy test_storage_read on storage.objects for select to authenticated using(true);");
  await db.exec('set role authenticated');
  await q('delete from storage.objects where name=$1',[afterFile.path]); // denied by RLS
  assert.equal((await q('select count(*)::int as n from storage.objects where name=$1',[afterFile.path]))[0].n,1);
  await q('delete from storage.objects where name=$1',[fileA.path]);await db.exec('reset role');
  let result=(await q('select finish_cometa_receipt_cleanup($1,$2) as result',[org,archive.id]))[0].result;assert.equal(result.remaining,2);
  assert.ok((await q('select receipt_archived_at from cometa_movements where id=$1',[a.id]))[0].receipt_archived_at);
  const restored=await upload(randomUUID(),'webp');await q("select attach_cometa_receipt($1,$2,$3,$4,'restaurada.webp')",[org,a.id,restored.operation,restored.path]);
  assert.equal(await allowed(restored.path),false);
  await db.exec('set role authenticated');for(const path of [fileB.path,fileC.path])await q('delete from storage.objects where name=$1',[path]);await db.exec('reset role');
  result=(await q('select finish_cometa_receipt_cleanup($1,$2) as result',[org,archive.id]))[0].result;assert.equal(result.remaining,0);
  await q('select finish_cometa_receipt_cleanup($1,$2)',[org,archive.id]);
  assert.equal((await q('select status from cometa_receipt_exports where id=$1',[archive.id]))[0].status,'cleaned');
  assert.equal((await q("select count(*)::int as n from audit_logs where action='cometa_receipts_storage_freed'"))[0].n,1);
  assert.deepEqual(await q('select id,kind,movement_date,amount,currency,category_id,concept,document_number,status,receipt_number,receipt_month from cometa_movements order by id'),finances);
  assert.equal((await q('select count(*)::int as n from storage.objects'))[0].n,2); // later receipt + restored receipt
  const data=(await q('select get_cometa_report($1) as result',[org]))[0].result;
  assert.ok(data.rows.find(row=>row.id===b.id).receipt_archived_at);
  assert.equal(data.rows.find(row=>row.id===a.id).receipt_archived_at,null);
 }finally{await db.close()}
});

test('ZIP is a valid UTF-8 stored archive with CRCs, a month folder and an injection-safe CSV index',async()=>{
 assert.equal(crc32(new TextEncoder().encode('123456789')),0xcbf43926);
 const row={movement_id:'one',path:'receipt.webp',receipt_name:'photo.jpg',receipt_number:1,receipt_month:'2026-11-01',movement_date:'2026-11-05',kind:'expense',category:'Insumos',concept:'=HYPERLINK("danger")',counterparty:'Proveedor',document_number:'A-1',amount:12.34,currency:'ARS',status:'valid',receipt_archived_at:null};
 assert.equal(receiptNumber(row),'202611-0001');assert.equal(receiptFilename(row),'0001.webp');assert.equal(receiptMonthName('2026-11'),'Noviembre 2026');
 const csv=receiptIndex([row]);assert.ok(csv.includes("'=HYPERLINK"));assert.ok(csv.includes('0001.webp'));
 async function* entries(){yield{name:'Noviembre 2026/0001.webp',data:new TextEncoder().encode('image bytes')};yield{name:'Noviembre 2026/indice.csv',data:new TextEncoder().encode(csv)}}
 const chunks=[];for await(const chunk of receiptZip(entries()))chunks.push(Buffer.from(chunk));const zip=Buffer.concat(chunks),names=[];let offset=0;
 while(zip.readUInt32LE(offset)===0x04034b50){
  assert.equal(zip.readUInt16LE(offset+6),0x0800);const size=zip.readUInt32LE(offset+18),length=zip.readUInt16LE(offset+26);
  const name=zip.subarray(offset+30,offset+30+length).toString('utf8'),data=zip.subarray(offset+30+length,offset+30+length+size);
  assert.equal(crc32(data),zip.readUInt32LE(offset+14));names.push(name);offset+=30+length+size;
 }
 assert.deepEqual(names,['Noviembre 2026/0001.webp','Noviembre 2026/indice.csv']);assert.equal(zip.readUInt32LE(zip.length-22),0x06054b50);assert.equal(zip.readUInt16LE(zip.length-12),2);
 async function* invalid(){yield{name:'../bad',data:new Uint8Array()}}
 await assert.rejects(async()=>{for await(const chunk of receiptZip(invalid()))void chunk},/Nombre/);
});
