"use client";

import * as React from "react";
import {Camera,Download,FileUp,Trash2} from "lucide-react";
import {CometaReceiptArchive,CometaAttachReceipt} from "./cometa-receipt-archive";
import {CometaSuppliers,useCometaSuppliers} from "./cometa-suppliers";
import type {CometaSupplier} from "./cometa-suppliers";
import {CometaGrain} from "./cometa-grain";
import {useActiveMembership} from "./auth-gate";
import {supabase} from "@/lib/supabase/client";
import {argentinaDay} from "@/lib/argentina-day";
import {prepareCometaReceipt,receiptNumber,receiptFilename} from "@/lib/cometa-receipts";
import {parsePdeExpenseAmount,formatPdeExpenseInput} from "@/lib/pde-expense-amounts";
import {formatPaymentCurrency} from "@/lib/urban-payment-amounts";
import type {InvoiceDraft} from "@/lib/cometa-invoice";

type Category={id:string;kind:"income"|"expense";name:string;description:string|null};
type Movement={id:string;kind:"income"|"expense";movement_date:string;category_id:string;category_name:string;concept:string;counterparty:string|null;document_number:string|null;notes:string|null;amount:number;currency:"ARS"|"USD";receipt_path:string|null;receipt_name:string|null;receipt_month?:string;receipt_number?:number;receipt_archived_at?:string|null};
type Report={categories:Category[];rows:Movement[];total:number;totals:{currency:string;income:number;expense:number}[];expensesByCategory:{currency:string;category_id:string;category_name:string;amount:number}[]};
const emptyReport:Report={categories:[],rows:[],total:0,totals:[],expensesByCategory:[]};
const money=(value:number,currency:string)=>formatPaymentCurrency(Number(value||0),currency);
const dateLabel=(value:string)=>value.split("-").reverse().join("/");
const palette=["#91b5d0","#b6d7a8","#f3d58b","#c3b4db","#e8b4a3","#97c9be","#c7c78d"];

export function CometaWorkspace(){
 const membership=useActiveMembership(),organization=membership?.organization_id,canWrite=!!membership&&membership.role!=="viewer";
 const [section,setSection]=React.useState("movements");
 const supplierData=useCometaSuppliers(organization);
 const [report,setReport]=React.useState<Report>(emptyReport),[loading,setLoading]=React.useState(false),[error,setError]=React.useState("");
 const [from,setFrom]=React.useState(()=>argentinaDay().slice(0,7)+"-01"),[to,setTo]=React.useState(""),[kind,setKind]=React.useState(""),[category,setCategory]=React.useState(""),[currency,setCurrency]=React.useState(""),[search,setSearch]=React.useState(""),[query,setQuery]=React.useState(""),[page,setPage]=React.useState(1),[refresh,setRefresh]=React.useState(0);
 const [formKind,setFormKind]=React.useState<"income"|"expense"|null>(null),[deleting,setDeleting]=React.useState<Movement|null>(null),[deletingBusy,setDeletingBusy]=React.useState(false),[ready,setReady]=React.useState<string|null>(null);
 const [attaching,setAttaching]=React.useState<Movement|null>(null);
 const [showDates,setShowDates]=React.useState(false);
 const dateFilter=React.useRef<HTMLDivElement>(null);
 React.useEffect(()=>{
  if(!showDates)return;
  const dismiss=(event:PointerEvent)=>{if(!dateFilter.current?.contains(event.target as Node))setShowDates(false)};
  const escape=(event:KeyboardEvent)=>{if(event.key==="Escape")setShowDates(false)};
  document.addEventListener("pointerdown",dismiss);document.addEventListener("keydown",escape);
  return()=>{document.removeEventListener("pointerdown",dismiss);document.removeEventListener("keydown",escape)};
 },[showDates]);
 const validRange=!from||!to||from<=to,pageSize=20,pages=Math.max(1,Math.ceil(report.total/pageSize));
 React.useEffect(()=>{const timer=setTimeout(()=>setQuery(search.trim()),300);return()=>clearTimeout(timer)},[search]);
 React.useEffect(()=>{setPage(1)},[from,to,kind,category,currency,query]);
 React.useEffect(()=>{
  if(!organization||!supabase)return;
  let cancelled=false;setReady(null);setReport(emptyReport);setError("");
  (async()=>{if(canWrite){const result=await supabase!.rpc("ensure_cometa_categories",{target_organization_id:organization});if(result.error)throw result.error}if(!cancelled)setReady(organization)})()
   .catch(err=>{if(!cancelled)setError(err.message||"No se pudo abrir El Cometa.")});
  return()=>{cancelled=true};
 },[organization,canWrite]);
 React.useEffect(()=>{
  if(!organization||ready!==organization||!supabase)return;
  if(!validRange){setLoading(false);setReport(current=>({...emptyReport,categories:current.categories}));return}
  let cancelled=false;setLoading(true);setError("");
  Promise.resolve(supabase.rpc("get_cometa_report",{target_organization_id:organization,from_date:from||null,to_date:to||null,kind_filter:kind||null,category_filter:category||null,currency_filter:currency||null,search_text:query||null,page_size:pageSize,page_offset:(page-1)*pageSize}))
   .then(({data,error:readError})=>{if(cancelled)return;if(readError){setError(readError.message);return}setReport(data as Report);if(page>Math.max(1,Math.ceil(Number(data.total)/pageSize)))setPage(1)})
   .catch(err=>{if(!cancelled)setError(err.message||"No se pudieron cargar los movimientos.")})
   .finally(()=>{if(!cancelled)setLoading(false)});
  return()=>{cancelled=true};
 },[organization,ready,from,to,kind,category,currency,query,page,refresh,validRange]);
 React.useEffect(()=>{
  if(!organization||!supabase)return;
  const channel=supabase.channel("cometa-"+organization).on("postgres_changes",{event:"*",schema:"public",table:"cometa_movements",filter:"organization_id=eq."+organization},()=>setRefresh(value=>value+1)).subscribe();
  return()=>{void supabase!.removeChannel(channel)};
 },[organization]);
 async function remove(){
  if(!deleting||deletingBusy||!supabase||!organization)return;
  setDeletingBusy(true);
  try{const {error:removeError}=await supabase.rpc("void_cometa_movement",{target_organization_id:organization,target_movement_id:deleting.id});if(removeError)throw removeError;
   setReport(current=>({...current,rows:current.rows.filter(row=>row.id!==deleting.id)}));setDeleting(null);setRefresh(value=>value+1);
  }catch(err){setError(err instanceof Error?err.message:"No se pudo anular el movimiento.")}
  finally{setDeletingBusy(false)}
 }
 async function download(row:Movement){
  if(!supabase||!row.receipt_path||row.receipt_archived_at)return;
  const filename=receiptNumber(row)+"."+receiptFilename(row).split(".").pop();
  const {data,error:downloadError}=await supabase.storage.from("receipts").createSignedUrl(row.receipt_path,60,{download:filename});
  if(downloadError){setError("No se pudo abrir el comprobante.");return}
  const link=document.createElement("a");link.href=data.signedUrl;link.rel="noopener noreferrer";link.download=filename;link.click();
 }
 const categoryOptions=report.categories.filter(item=>!kind||item.kind===kind);
 return <div className="page-stack cometa-workspace">
  <header className="page-header"><div><h2>El Cometa</h2><p>Actividad agrícola</p></div></header>
  <nav className="segmented-control cometa-section-tabs" aria-label="Secciones de El Cometa">{[{id:"movements",label:"Caja"},{id:"harvest",label:"Registro de cosecha"},{id:"suppliers",label:"Proveedores"},{id:"storage",label:"Acopios"}].map(item=><button key={item.id} type="button" className={section===item.id?"active":""} aria-pressed={section===item.id} onClick={()=>{setSection(item.id);setShowDates(false);if(item.id==="suppliers")supplierData.reload()}}>{item.label}</button>)}</nav>
  {(section==="harvest"||section==="storage")&&organization&&<CometaGrain key={organization+section} organization={organization} canWrite={canWrite} view={section}/>}
  {section==="suppliers"&&organization&&<CometaSuppliers key={organization} organization={organization} canWrite={canWrite} {...supplierData} onChanged={supplierData.reload}/>}
  {section==="movements"&&<>
  <div className="inline-actions cometa-cash-actions"><button className="secondary-button danger-outline-button" disabled={!canWrite||!ready} onClick={()=>setFormKind("expense")}>Registrar egreso</button><button className="secondary-button success-outline-button" disabled={!canWrite||!ready} onClick={()=>setFormKind("income")}>Registrar ingreso</button>{canWrite&&organization&&<CometaReceiptArchive organization={organization} onChanged={()=>setRefresh(value=>value+1)}/>}</div>
  <section className="panel cometa-filters" aria-label="Filtros de movimientos">
   <label className="field">Buscar<input autoComplete="off" type="search" value={search} onChange={event=>setSearch(event.target.value)} placeholder="Concepto, persona o factura"/></label>
   <label className="field">Tipo<select value={kind} onChange={event=>{setKind(event.target.value);setCategory("")}}><option value="">Ingresos y egresos</option><option value="income">Ingresos</option><option value="expense">Egresos</option></select></label>
   <label className="field">Categoría<select value={category} onChange={event=>setCategory(event.target.value)}><option value="">Todas</option>{categoryOptions.map(item=><option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
   <label className="field">Moneda<select value={currency} onChange={event=>setCurrency(event.target.value)}><option value="">Pesos y dólares</option><option value="ARS">Pesos argentinos</option><option value="USD">Dólares</option></select></label>
   <div className="field cometa-date-filter" ref={dateFilter}><span>Personalizado</span><button className="secondary-button cometa-date-toggle" type="button" aria-expanded={showDates} aria-controls="cometa-date-range" onClick={()=>setShowDates(value=>!value)} title={from&&to?dateLabel(from)+" – "+dateLabel(to):from?"Desde "+dateLabel(from):to?"Hasta "+dateLabel(to):"Todas las fechas"}><span className="cometa-date-value">{from&&to?dateLabel(from)+" – "+dateLabel(to):from?"Desde "+dateLabel(from):to?"Hasta "+dateLabel(to):"Todas las fechas"}</span><span aria-hidden="true">▾</span></button>
    {showDates&&<div id="cometa-date-range" className="cometa-date-popover" role="group" aria-label="Rango de fechas"><label className="field">Desde<input autoComplete="off" type="date" value={from} onChange={event=>setFrom(event.target.value)}/></label><label className="field">Hasta<input autoComplete="off" type="date" value={to} onChange={event=>setTo(event.target.value)}/></label><div className="inline-actions"><button className="secondary-button compact-action" type="button" onClick={()=>{setFrom("");setTo("");setKind("");setCategory("");setCurrency("");setSearch("");setShowDates(false)}}>Ver todo</button><button className="primary-button compact-action" type="button" onClick={()=>setShowDates(false)}>Listo</button></div></div>}
   </div>
  </section>
  {!validRange&&<p className="warning-box">La fecha Desde debe ser anterior o igual a Hasta.</p>}
  {error&&<p className="warning-box" role="alert">{error}</p>}
  {loading&&<p className="sync-message" role="status">Actualizando movimientos...</p>}
  <div className="cometa-currency-panels">{["ARS","USD"].filter(code=>!currency||currency===code).map(code=>{
   const totals=report.totals.find(item=>item.currency===code),income=Number(totals?.income||0),expense=Number(totals?.expense||0),groups=report.expensesByCategory.filter(item=>item.currency===code);
   return <section className="panel cometa-currency-panel" key={code}><h3>{code==="ARS"?"Pesos argentinos":"Dólares"}</h3><div className="cometa-totals"><div><span>Ingresos</span><strong className="cometa-income">{money(income,code)}</strong></div><div><span>Egresos</span><strong className="cometa-expense">{money(expense,code)}</strong></div><div><span>Saldo</span><strong>{money(income-expense,code)}</strong></div></div><h4>Gastos acumulados por categoría</h4>{groups.length===0?<p className="empty-state">Todavía no hay egresos para estos filtros.</p>:<div className="cometa-category-chart">{groups.map((group,index)=><div className="cometa-category-row" key={group.category_id}><div><span>{group.category_name}</span><strong>{money(group.amount,code)}</strong></div><div className="cometa-category-track"><span style={{width:(expense?Number(group.amount)/expense*100:0)+"%",background:palette[index%palette.length]}}/></div></div>)}</div>}</section>;
  })}</div>
  <section className="panel"><div className="section-title"><h3>Ingresos y egresos</h3><span>{report.total} movimientos</span></div>{report.rows.length===0?<p className="empty-state">{loading?"Cargando movimientos...":"No hay movimientos para estos filtros."}</p>:<div className="responsive-table"><table className="cometa-movements-table"><thead><tr>{["Fecha","Tipo","Categoría","Concepto","Contraparte","Factura","Moneda","Importe","Comprobante","Acciones"].map(label=><th key={label}>{label}</th>)}</tr></thead><tbody>{report.rows.map(row=><tr key={row.id}><td>{dateLabel(row.movement_date)}</td><td><span className={"status-pill "+(row.kind==="income"?"success":"danger")}>{row.kind==="income"?"Ingreso":"Egreso"}</span></td><td>{row.category_name}</td><td>{row.concept}{row.notes&&<small className="payment-allocation-detail">{row.notes}</small>}</td><td>{row.counterparty||"-"}</td><td>{row.document_number||"-"}</td><td>{row.currency}</td><td className={row.kind==="income"?"cometa-income":"cometa-expense"}><strong>{money(row.amount,row.currency)}</strong></td><td><strong>{receiptNumber(row)}</strong><small className="payment-allocation-detail">{row.receipt_archived_at?"Archivado localmente":row.receipt_path?"Online":"Sin adjuntar"}</small><div className="inline-actions compact-actions">{row.receipt_path&&!row.receipt_archived_at&&<button className="circle-icon-button" onClick={()=>download(row)} aria-label={"Descargar comprobante "+receiptNumber(row)}><Download size={16}/></button>}{canWrite&&(!row.receipt_path||row.receipt_archived_at)&&<button className="circle-icon-button" onClick={()=>setAttaching(row)} aria-label={"Adjuntar comprobante a "+row.concept}><FileUp size={16}/></button>}</div></td><td>{canWrite&&<button className="circle-icon-button danger-icon-button" onClick={()=>setDeleting(row)} aria-label={"Anular "+row.concept}><Trash2 size={16}/></button>}</td></tr>)}</tbody></table></div>}
   {pages>1&&<div className="table-pagination"><span>Página {page} de {pages}</span><div className="inline-actions"><button className="secondary-button compact-action" disabled={page<=1||loading} onClick={()=>setPage(value=>value-1)}>Anterior</button><button className="secondary-button compact-action" disabled={page>=pages||loading} onClick={()=>setPage(value=>value+1)}>Siguiente</button></div></div>}
  </section>
  </>}
  {formKind&&organization&&<CometaMovementModal kind={formKind} organization={organization} categories={report.categories.filter(item=>item.kind===formKind)} suppliers={supplierData.suppliers} supplierError={supplierData.error} onClose={()=>setFormKind(null)} onSaved={()=>{setFormKind(null);setRefresh(value=>value+1)}}/>}
  {attaching&&organization&&<CometaAttachReceipt organization={organization} movementId={attaching.id} onClose={()=>setAttaching(null)} onSaved={()=>{setAttaching(null);setRefresh(value=>value+1)}}/>}
  {deleting&&<div className="modal-backdrop stacked-modal"><section className="modal" role="dialog" aria-modal="true" aria-label="Anular movimiento"><h3>Anular movimiento</h3><p>{deleting.concept} · {money(deleting.amount,deleting.currency)}</p><p>Se quitará del saldo y del gráfico. El comprobante y la auditoría quedan conservados.</p><div className="modal-actions"><button className="secondary-button" disabled={deletingBusy} onClick={()=>setDeleting(null)}>Cancelar</button><button className="primary-button danger-confirm-button" disabled={deletingBusy} onClick={remove}>{deletingBusy?"Anulando...":"Anular movimiento"}</button></div></section></div>}
 </div>;
}

export function CometaMovementModal({kind,organization,categories,suppliers=[],supplierError="",onClose,onSaved}:{kind:"income"|"expense";organization:string;categories:Category[];suppliers?:CometaSupplier[];supplierError?:string;onClose:()=>void;onSaved:()=>void}){
 const [scope]=React.useState(()=>crypto.randomUUID()),[date,setDate]=React.useState(argentinaDay),[category,setCategory]=React.useState(""),[currency,setCurrency]=React.useState("ARS"),[amount,setAmount]=React.useState(""),[concept,setConcept]=React.useState(""),[party,setParty]=React.useState(""),[number,setNumber]=React.useState(""),[notes,setNotes]=React.useState("");
 const [file,setFile]=React.useState<File|null>(null),[busy,setBusy]=React.useState(false),[reading,setReading]=React.useState(false),[error,setError]=React.useState(""),[aiEnabled,setAiEnabled]=React.useState(false),[draft,setDraft]=React.useState(false),[reviewed,setReviewed]=React.useState(false),[warnings,setWarnings]=React.useState<string[]>([]);
 const working=React.useRef(false),attempt=React.useRef<{signature:string;id:string}|null>(null),camera=React.useRef<HTMLInputElement>(null),upload=React.useRef<HTMLInputElement>(null);
 const locked=busy||reading,field=(name:string)=>"cometa-"+scope+"-"+name;
 React.useEffect(()=>{const controller=new AbortController();fetch("/api/cometa/invoice",{signal:controller.signal}).then(response=>response.json()).then(data=>setAiEnabled(data.enabled===true)).catch(()=>{});return()=>controller.abort()},[]);
 const change=(set:React.Dispatch<React.SetStateAction<string>>,value:string)=>{set(value);setReviewed(false)};
 async function selectFile(value:File|null){
  if(!value||working.current)return;
  if(!["application/pdf","image/jpeg","image/png","image/webp"].includes(value.type)||value.size>20*1024*1024){setError("Usá PDF, JPG, PNG o WebP de hasta 20 MB.");return}
  working.current=true;setBusy(true);setError("");
  try{setFile(await prepareCometaReceipt(value));setReviewed(false);setWarnings([])}
  catch(err){setError(err instanceof Error?err.message:"No se pudo convertir la imagen a WebP.")}
  finally{working.current=false;setBusy(false)}
 }
 async function readInvoice(){
  if(!file||working.current||!supabase)return;
  if(file.size>3*1024*1024){setError("Para leer automáticamente, elegí un archivo de hasta 3 MB. Podés adjuntarlo y completar los datos manualmente.");return}
  working.current=true;setReading(true);setError("");
  try{
   const {data:session}=await supabase.auth.getSession();if(!session.session)throw new Error("Volvé a iniciar sesión.");
   const form=new FormData();form.set("file",file);form.set("kind",kind);form.set("organizationId",organization);
   const response=await fetch("/api/cometa/invoice",{method:"POST",headers:{Authorization:"Bearer "+session.session.access_token},body:form});
   const result=await response.json();if(!response.ok)throw new Error(result.error||"No se pudo leer la factura.");
   const data=result.draft as InvoiceDraft;
   setDate(data.date||"");setAmount(data.amount===null?"":formatPdeExpenseInput(data.amount));setCurrency(data.currency||"");setConcept(data.concept||"");setParty(data.counterparty||"");setNumber(data.documentNumber||"");setCategory(data.categoryId||"");
   setWarnings([...data.warnings,...(!data.currency?["No se identificó la moneda: elegí pesos o dólares."]:[])]);setDraft(true);setReviewed(false);
  }catch(err){setError(err instanceof Error?err.message:"No se pudo leer la factura. Podés cargar los datos manualmente.")}
  finally{working.current=false;setReading(false)}
 }
 async function save(event:React.FormEvent<HTMLFormElement>){
  event.preventDefault();if(working.current||!supabase)return;
  const parsed=parsePdeExpenseAmount(amount);
  if(parsed===null){setError("Ingresá un importe mayor a cero, con hasta dos decimales.");return}
  if(!concept.trim()||!category||!date||!["ARS","USD"].includes(currency)){setError("Completá fecha, categoría, moneda, importe y concepto.");return}
  if(draft&&!reviewed){setError("Revisá los datos de la factura y marcá la confirmación.");return}
  const values={date,kind,category,currency,amount:parsed,concept:concept.trim(),party:party.trim(),number:number.trim(),notes:notes.trim(),file:file?[file.name,file.size,file.lastModified]:null};
  const signature=JSON.stringify(values);if(attempt.current?.signature!==signature)attempt.current={signature,id:crypto.randomUUID()};
  const operation=attempt.current.id;working.current=true;setBusy(true);setError("");
  try{
   let receiptPath:string|null=null;
   if(file){
    const ext=({"application/pdf":"pdf","image/jpeg":"jpg","image/png":"png","image/webp":"webp"})[file.type]||"pdf";
    receiptPath="org/"+organization+"/cometa/"+operation+"/receipt."+ext;
    const {error:uploadError}=await supabase.storage.from("receipts").upload(receiptPath,file,{upsert:false,contentType:file.type});
    if(uploadError&&String((uploadError as {statusCode?:string}).statusCode)!=="409")throw uploadError;
   }
   const {error:saveError}=await supabase.rpc("register_cometa_movement",{target_organization_id:organization,movement_kind:kind,entry_date:date,entry_category_id:category,entry_amount:parsed,entry_currency:currency,entry_concept:concept.trim(),entry_counterparty:party.trim()||null,entry_document_number:number.trim()||null,entry_notes:notes.trim()||null,receipt_path:receiptPath,receipt_name:file?.name||null,operation_id:operation});
   if(saveError)throw saveError;
   attempt.current=null;onSaved();
  }catch(err){setError(err instanceof Error?err.message:(err as {message?:string})?.message||"No se pudo guardar. Podés reintentar sin duplicar el movimiento.")}
  finally{working.current=false;setBusy(false)}
 }
 return <div className="modal-backdrop stacked-modal"><section className="modal wide-modal cometa-movement-modal" role="dialog" aria-modal="true" aria-label={kind==="income"?"Registrar ingreso":"Registrar egreso"} aria-busy={locked}>
  <div className="section-title"><div><h3>{kind==="income"?"Registrar ingreso":"Registrar egreso"}</h3><p>El Cometa · Actividad agrícola</p></div><button className="icon-button" type="button" disabled={locked} onClick={onClose} aria-label="Cerrar">X</button></div>
  <div className="cometa-invoice-upload"><div className="inline-actions"><button className="secondary-button compact-action" disabled={locked} onClick={()=>camera.current?.click()}><Camera size={16}/> Sacar foto</button><button className="secondary-button compact-action" disabled={locked} onClick={()=>upload.current?.click()}><FileUp size={16}/> Cargar PDF o imagen</button></div>
   <input hidden ref={camera} type="file" accept="image/jpeg,image/png,image/webp" capture="environment" onChange={event=>{void selectFile(event.target.files?.[0]||null);event.target.value=""}}/>
   <input hidden ref={upload} type="file" accept=".pdf,.jpg,.jpeg,.png,.webp" onChange={event=>{void selectFile(event.target.files?.[0]||null);event.target.value=""}}/>
   {file&&<div className="inline-actions"><span>{file.name}</span>{aiEnabled&&<button className="secondary-button compact-action" disabled={locked} onClick={readInvoice}>{reading?"Leyendo factura...":"Leer factura"}</button>}<button className="small-button" disabled={locked} onClick={()=>{setFile(null);setReviewed(false)}}>Quitar</button></div>}
   <small>{aiEnabled?"Podés leer una factura para preparar un borrador o completar los campos manualmente.":"Podés adjuntar el comprobante ahora o después. Las fotos se guardan como WebP; los PDF conservan su formato."}</small>
  </div>
  {error&&<p className="warning-box" role="alert">{error}</p>}
  {draft&&<p className="warning-box" role="status">Borrador preparado. Verificá los datos con la factura antes de guardar.{warnings.map((warning,index)=><span className="cometa-warning-line" key={index}>{warning}</span>)}</p>}
  <form className="modal-form" autoComplete="off" onSubmit={save}><fieldset disabled={locked} className="cometa-form-fields"><div className="form-grid compact-form-grid">
   <label>Fecha<input type="date" autoComplete="off" name={field("date")} required value={date} onChange={event=>change(setDate,event.target.value)}/></label>
   <label>Categoría<select autoComplete="off" name={field("category")} required value={category} onChange={event=>change(setCategory,event.target.value)}><option value="">Seleccionar categoría</option>{categories.map(item=><option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
   {categories.find(item=>item.id===category)?.description&&<p className="cometa-category-help form-wide">{categories.find(item=>item.id===category)?.description}</p>}
   <label>Moneda<select autoComplete="off" name={field("currency")} required value={currency} onChange={event=>change(setCurrency,event.target.value)}><option value="">Seleccionar moneda</option><option value="ARS">Pesos argentinos</option><option value="USD">Dólares</option></select></label>
   <label>Importe<input type="text" inputMode="decimal" autoComplete="off" name={field("amount")} required placeholder="0,00" value={amount} onChange={event=>change(setAmount,event.target.value)} onBlur={()=>{const value=parsePdeExpenseAmount(amount);if(value!==null)setAmount(formatPdeExpenseInput(value))}}/></label>
   <label className="form-wide">Concepto<input autoComplete="off" name={field("concept")} required maxLength={500} value={concept} onChange={event=>change(setConcept,event.target.value)}/></label>
   <label>{kind==="income"?"Cliente / comprador":"Proveedor"}<input autoComplete="off" name={field("party")} list={kind==="expense"?field("suppliers"):undefined} maxLength={200} value={party} onChange={event=>change(setParty,event.target.value)} placeholder={kind==="expense"?"Escribí para buscar un proveedor":undefined}/></label>{kind==="expense"&&<datalist id={field("suppliers")}>{suppliers.map(supplier=><option key={supplier.id} value={supplier.name}>{supplier.tax_id||supplier.contact}</option>)}</datalist>}
   {kind==="expense"&&supplierError&&<p className="warning-box form-wide">No se pudieron cargar las sugerencias de proveedores. Podés escribir el nombre manualmente.</p>}
   <label>Número de factura<input autoComplete="off" name={field("number")} maxLength={100} value={number} onChange={event=>change(setNumber,event.target.value)}/></label>
   <label className="form-wide">Observaciones<textarea autoComplete="off" name={field("notes")} rows={3} maxLength={4000} value={notes} onChange={event=>change(setNotes,event.target.value)}/></label>
  </div>{draft&&<label className="checkbox-line"><input type="checkbox" checked={reviewed} onChange={event=>setReviewed(event.target.checked)}/>Revisé los datos con la factura y confirmo que son correctos.</label>}
  </fieldset><div className="modal-actions"><button className="secondary-button" type="button" disabled={locked} onClick={onClose}>Cancelar</button><button className="primary-button" type="submit" disabled={locked||(draft&&!reviewed)}>{busy?"Guardando...":kind==="income"?"Guardar ingreso":"Guardar egreso"}</button></div></form>
 </section></div>;
}
