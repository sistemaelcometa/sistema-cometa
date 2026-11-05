"use client";
import * as React from "react";
import {Download,FileUp} from "lucide-react";
import {supabase} from "@/lib/supabase/client";
import {argentinaDay} from "@/lib/argentina-day";
import {prepareCometaReceipt,receiptMonthName,receiptFilename,receiptIndex,receiptZip,receiptNumber} from "@/lib/cometa-receipts";
import type {ReceiptSnapshot,ReceiptManifest} from "@/lib/cometa-receipts";
type ExportRecord={id:string;period_month:string;entries:ReceiptSnapshot[];status:"preparing"|"ready"|"cleaned";created_at:string;};
type SaveTarget={createWritable:()=>Promise<{write:(chunk:Uint8Array<ArrayBuffer>)=>Promise<void>;close:()=>Promise<void>;abort:()=>Promise<void>}>};
type SavePicker=(options:{suggestedName:string;types:{description:string;accept:Record<string,string[]>}[]})=>Promise<SaveTarget>;
const errorMessage=(error:unknown,fallback:string)=>error instanceof Error?error.message:(error as {message?:string})?.message||fallback;

export function CometaReceiptArchive({organization,onChanged}:{organization:string;onChanged:()=>void}){
 const [open,setOpen]=React.useState(false),[month,setMonth]=React.useState(()=>argentinaDay().slice(0,7)),[records,setRecords]=React.useState<ExportRecord[]>([]);
 const [busy,setBusy]=React.useState(false),[message,setMessage]=React.useState(""),[progress,setProgress]=React.useState(""),[selected,setSelected]=React.useState(""),[confirmed,setConfirmed]=React.useState(false);
 const working=React.useRef(false),loadVersion=React.useRef(0);
 const chosen=records.find(record=>record.id===selected&&record.status==="ready");
 const load=React.useCallback(async()=>{
  if(!supabase)return;
  const version=++loadVersion.current;
  const {data,error}=await supabase.from("cometa_receipt_exports").select("id,period_month,entries,status,created_at").eq("organization_id",organization).eq("period_month",month+"-01").in("status",["ready","cleaned"]).order("created_at",{ascending:false}).limit(20);
  if(version!==loadVersion.current)return;
  if(error){setMessage(error.message);return}
  setRecords((data??[]) as ExportRecord[]);
 },[organization,month]);
 React.useEffect(()=>{setRecords([]);setSelected("");setConfirmed(false);setMessage("");if(open)void load();return()=>{loadVersion.current++}},[open,load]);
 async function download(){
  if(working.current||!supabase)return;
  let monthName:string;
  try{monthName=receiptMonthName(month)}catch{setMessage("Elegí el mes que querés descargar.");return}
  const archiveName=monthName+" - copia "+crypto.randomUUID().slice(0,8)+".zip";
  working.current=true;setBusy(true);setMessage("");setProgress("Preparando descarga...");
  let writable:Awaited<ReturnType<SaveTarget["createWritable"]>>|null=null,closed=false;
  try{
   // Open the native picker before awaiting network work to retain the user gesture.
   const picker=(window as unknown as {showSaveFilePicker?:SavePicker}).showSaveFilePicker;
   const handle=picker?await picker.call(window,{suggestedName:archiveName,types:[{description:"Archivo ZIP",accept:{"application/zip":[".zip"]}}]}):null;
   const {data,error}=await supabase.rpc("begin_cometa_receipt_export",{target_organization_id:organization,export_month:month+"-01"});
   if(error)throw error;
   const record=data as ExportRecord,rows=record.entries,files=rows.filter(row=>row.path&&!row.receipt_archived_at),manifest:ReceiptManifest[]=[];
   if(handle)writable=await handle.createWritable();
   async function* entries(){
    for(let index=0;index<files.length;index++){
     const row=files[index];setProgress("Descargando "+(index+1)+" de "+files.length+" comprobantes...");
     const {data:blob,error:readError}=await supabase!.storage.from("receipts").download(row.path!);
     if(readError||!blob||blob.size===0)throw new Error("No se pudo descargar el comprobante "+receiptNumber(row)+". No se habilitó la limpieza.");
     const bytes=new Uint8Array(await blob.arrayBuffer()),hash=await crypto.subtle.digest("SHA-256",bytes);
     manifest.push({movement_id:row.movement_id,path:row.path!,bytes:bytes.length,sha256:Array.from(new Uint8Array(hash),byte=>byte.toString(16).padStart(2,"0")).join("")});
     yield {name:monthName+"/"+receiptFilename(row),data:bytes};
    }
    const utf8=new TextEncoder();
    yield {name:monthName+"/indice.csv",data:utf8.encode(receiptIndex(rows))};
    yield {name:monthName+"/manifest.json",data:utf8.encode(JSON.stringify({export_id:record.id,month,files:manifest},null,2))};
   }
   const chunks:BlobPart[]=[];let size=0;
   for await(const chunk of receiptZip(entries())){
    if(writable)await writable.write(Uint8Array.from(chunk));
    else{size+=chunk.length;if(size>250*1024*1024)throw new Error("La descarga supera 250 MB. Usá Chrome o Edge en una computadora para guardarla directamente en disco.");chunks.push(Uint8Array.from(chunk))}
   }
   if(writable){await writable.close();closed=true}
   else{
    const url=URL.createObjectURL(new Blob(chunks,{type:"application/zip"})),link=document.createElement("a");
    link.href=url;link.download=archiveName;link.click();setTimeout(()=>URL.revokeObjectURL(url),60000);
   }
   const {error:completeError}=await supabase.rpc("complete_cometa_receipt_export",{target_organization_id:organization,target_export_id:record.id,file_manifest:manifest});
   if(completeError)throw new Error("El ZIP fue generado, pero no se pudo registrar la exportación. Conservá la descarga; los archivos siguen online.");
   await load();setSelected(record.id);setConfirmed(false);setMessage("ZIP generado. Abrilo y verificá los comprobantes antes de liberar espacio.");
  }catch(error){
   if((error as {name?:string})?.name!=="AbortError")setMessage(errorMessage(error,"No se pudo completar la descarga. Los comprobantes siguen online."));
  }finally{
   if(writable&&!closed)await writable.abort().catch(()=>{});
   working.current=false;setBusy(false);setProgress("");
  }
 }
 async function cleanup(){
  if(!chosen||!confirmed||working.current||!supabase)return;
  working.current=true;setBusy(true);setMessage("");setProgress("Liberando espacio...");
  try{
   const {error:authError}=await supabase.rpc("authorize_cometa_receipt_cleanup",{target_organization_id:organization,target_export_id:chosen.id});if(authError)throw authError;
   const paths=chosen.entries.filter(row=>row.path&&!row.receipt_archived_at).map(row=>row.path!);
   let failure:unknown=null;
   for(let index=0;index<paths.length;index+=100){
    const {error}=await supabase.storage.from("receipts").remove(paths.slice(index,index+100));if(error){failure=error;break}
   }
   const {data,error}=await supabase.rpc("finish_cometa_receipt_cleanup",{target_organization_id:organization,target_export_id:chosen.id});
   if(error)throw error;
   await load();onChanged();setConfirmed(false);
   if(failure||Number(data.remaining)>0)setMessage("La limpieza quedó incompleta. Conservá el ZIP y reintentá; los archivos que siguen online no se marcaron como archivados.");
   else{setSelected("");setMessage("Espacio liberado. Los movimientos conservan sus números e importes. Los comprobantes están en tu descarga local.")}
  }catch(error){setMessage(errorMessage(error,"No se pudo liberar espacio. Podés reintentar."));await load();onChanged()}
  finally{working.current=false;setBusy(false);setProgress("")}
 }
 return <><button className="secondary-button cometa-archive-trigger" type="button" onClick={()=>setOpen(true)}><Download size={18}/>Descargar facturas</button>{open&&<div className="modal-backdrop stacked-modal"><section className="modal wide-modal cometa-archive-modal" role="dialog" aria-modal="true" aria-label="Facturas del mes" aria-busy={busy}>
  <div className="section-title"><div><h3>Facturas del mes</h3><p>El Cometa</p></div><button className="icon-button" disabled={busy} onClick={()=>setOpen(false)} aria-label="Cerrar">X</button></div>
  <label className="field">Mes de los comprobantes<input type="month" value={month} disabled={busy} onChange={event=>setMonth(event.target.value)}/></label>
  <p>Descarga todos los comprobantes online del mes, incluidos los de movimientos anulados, con un índice de movimientos. Cada archivo conserva su número interno. Los filtros de la tabla no limitan esta descarga.</p>
  <button className="primary-button cometa-archive-button" disabled={busy||!month} onClick={download}><Download size={18}/>{busy?progress:"Descargar ZIP del mes"}</button>
  {message&&<p className="warning-box" role="status">{message}</p>}
  {records.length>0&&<div className="cometa-export-list"><h4>Descargas preparadas</h4>{records.map(record=><div key={record.id} className="history-line-card"><span>{new Date(record.created_at).toLocaleString("es-AR")} · {record.entries.filter(row=>row.path&&!row.receipt_archived_at).length} archivos</span>{record.status==="cleaned"?<strong>Archivados localmente</strong>:<button className="secondary-button compact-action" disabled={busy} onClick={()=>{setSelected(record.id);setConfirmed(false)}}>{selected===record.id?"Seleccionada":"Seleccionar para liberar espacio"}</button>}</div>)}</div>}
  {chosen&&<div className="cometa-cleanup-section"><h4>Liberar espacio online</h4><p>Se eliminarán sólo los archivos incluidos en esta descarga. Los movimientos, números de comprobante e importes se conservan.</p><label className="checkbox-line"><input type="checkbox" disabled={busy} checked={confirmed} onChange={event=>setConfirmed(event.target.checked)}/>Guardé el ZIP, lo abrí y verifiqué que puedo consultar sus comprobantes.</label><button className="secondary-button danger-outline-button" disabled={busy||!confirmed} onClick={cleanup}>Eliminar comprobantes online de esta descarga</button></div>}
 </section></div>}</>;
}

export function CometaAttachReceipt({organization,movementId,onClose,onSaved}:{organization:string;movementId:string;onClose:()=>void;onSaved:()=>void}){
 const [file,setFile]=React.useState<File|null>(null),[busy,setBusy]=React.useState(false),[error,setError]=React.useState(""),[operation,setOperation]=React.useState(()=>crypto.randomUUID());
 const working=React.useRef(false);
 async function select(value:File|null){if(!value||working.current)return;working.current=true;setBusy(true);setError("");try{setFile(await prepareCometaReceipt(value));setOperation(crypto.randomUUID())}catch(err){setError(errorMessage(err,"No se pudo preparar el archivo."))}finally{working.current=false;setBusy(false)}}
 async function save(){
  if(!file||working.current||!supabase)return;
  working.current=true;setBusy(true);setError("");
  try{
   const path="org/"+organization+"/cometa/"+operation+"/receipt."+(file.type==="application/pdf"?"pdf":"webp");
   const {error:uploadError}=await supabase.storage.from("receipts").upload(path,file,{contentType:file.type,upsert:false});
   if(uploadError&&String((uploadError as {statusCode?:string}).statusCode)!=="409")throw uploadError;
   const {error:linkError}=await supabase.rpc("attach_cometa_receipt",{target_organization_id:organization,target_movement_id:movementId,receipt_operation_id:operation,file_path:path,file_name:file.name});
   if(linkError)throw linkError;
   onSaved();
  }catch(err){setError(errorMessage(err,"No se pudo adjuntar el comprobante."))}
  finally{working.current=false;setBusy(false)}
 }
 return <div className="modal-backdrop stacked-modal"><section className="modal" role="dialog" aria-modal="true" aria-label="Adjuntar comprobante"><div className="section-title"><h3>Adjuntar comprobante</h3><button className="icon-button" disabled={busy} onClick={onClose} aria-label="Cerrar">X</button></div><p>La foto se guarda como WebP. Los PDF conservan su formato.</p><label>Foto o PDF<input type="file" disabled={busy} accept=".pdf,.jpg,.jpeg,.png,.webp" onChange={event=>{void select(event.target.files?.[0]||null);event.target.value=""}}/></label>{file&&<p>{file.name}</p>}{error&&<p className="warning-box" role="alert">{error}</p>}<div className="modal-actions"><button className="secondary-button" disabled={busy} onClick={onClose}>Cancelar</button><button className="primary-button" disabled={busy||!file} onClick={save}><FileUp size={16}/> {busy?"Guardando...":"Adjuntar comprobante"}</button></div></section></div>;
}
