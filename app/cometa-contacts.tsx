"use client";
import * as React from "react";
import {supabase} from "@/lib/supabase/client";

import {contactRoleLabels} from "@/lib/cometa-contacts";
import type {CometaContact,ContactRole} from "@/lib/cometa-contacts";
export function useCometaContacts(organization?:string){
 const [contacts,setContacts]=React.useState<CometaContact[]>([]),[error,setError]=React.useState(""),[loading,setLoading]=React.useState(false),[version,setVersion]=React.useState(0);
 React.useEffect(()=>{
  let cancelled=false;setContacts([]);setError("");
  if(!organization||!supabase)return;
  setLoading(true);
  (async()=>{
   const rows:CometaContact[]=[];
   for(let offset=0;;offset+=1000){
    const {data,error}=await supabase!.from("cometa_suppliers").select("id,name,tax_id,contact,party_role").eq("organization_id",organization).is("archived_at",null).order("name").order("id").range(offset,offset+999);
    if(error)throw error;if(cancelled)return;rows.push(...data);if(data.length<1000)break;
   }
   if(!cancelled)setContacts(rows);
  })().catch(err=>{if(!cancelled)setError(err.message||"No se pudieron cargar los contactos.")}).finally(()=>{if(!cancelled)setLoading(false)});
  return()=>{cancelled=true};
 },[organization,version]);
 return {contacts,error,loading,reload:()=>setVersion(value=>value+1)};
}

export function CometaContacts({organization,canWrite,contacts,loading,error,onChanged}:{organization:string;canWrite:boolean;contacts:CometaContact[];loading:boolean;error:string;onChanged:()=>void}){
 const [search,setSearch]=React.useState(""),[editing,setEditing]=React.useState<CometaContact|null|undefined>(),[name,setName]=React.useState(""),[taxId,setTaxId]=React.useState(""),[contact,setContact]=React.useState(""),[busy,setBusy]=React.useState(false),[message,setMessage]=React.useState(""),[archiving,setArchiving]=React.useState<CometaContact|null>(null);
 const [role,setRole]=React.useState<ContactRole>("supplier"),[roleFilter,setRoleFilter]=React.useState("");
 const working=React.useRef(false);
 function edit(row:CometaContact|null){setEditing(row);setRole(row?.party_role||"supplier");setName(row?.name||"");setTaxId(row?.tax_id||"");setContact(row?.contact||"");setMessage("")}
 async function save(event:React.FormEvent){
  event.preventDefault();if(!supabase||working.current)return;working.current=true;setBusy(true);setMessage("");
  try{const {error}=await supabase.rpc("save_cometa_contact",{target_organization_id:organization,target_contact_id:editing?.id||null,contact_name:name.trim(),contact_tax_id:taxId.trim(),contact_details:contact.trim(),contact_role:role});if(error)throw error;setEditing(undefined);onChanged()}
  catch(err){setMessage((err as {message?:string}).message||"No se pudo guardar el contacto.")}
  finally{working.current=false;setBusy(false)}
 }
 async function archive(){
  if(!supabase||!archiving||working.current)return;working.current=true;setBusy(true);setMessage("");
  try{const {error}=await supabase.rpc("archive_cometa_supplier",{target_organization_id:organization,target_supplier_id:archiving.id});if(error)throw error;setArchiving(null);onChanged()}
  catch(err){setMessage((err as {message?:string}).message||"No se pudo archivar el contacto.")}
  finally{working.current=false;setBusy(false)}
 }
 const rows=contacts.filter(row=>(!roleFilter||row.party_role===roleFilter||row.party_role==="both")&&[row.name,row.tax_id,row.contact].some(text=>text.toLocaleLowerCase().includes(search.trim().toLocaleLowerCase())));
 return <section className="panel"><div className="section-title"><h3>Proveedores y compradores</h3>{canWrite&&<button className="secondary-button" onClick={()=>edit(null)}>Agregar contacto</button>}</div>
  <div className="cometa-contact-filters"><label className="field">Buscar contacto<input type="search" autoComplete="off" value={search} onChange={event=>setSearch(event.target.value)} placeholder="Nombre, CUIT o contacto"/></label><label className="field">Tipo<select aria-label="Filtrar contactos por tipo" value={roleFilter} onChange={event=>setRoleFilter(event.target.value)}><option value="">Todos</option><option value="supplier">Proveedores</option><option value="buyer">Compradores</option></select></label></div>
  {error&&<p className="warning-box" role="alert">{error}</p>}{message&&editing===undefined&&!archiving&&<p className="warning-box" role="alert">{message}</p>}
  {loading?<p role="status">Cargando contactos...</p>:rows.length===0?<p className="empty-state">No hay contactos para mostrar.</p>:<div className="responsive-table"><table className="cometa-suppliers-table"><thead><tr><th>Nombre / razón social</th><th>Tipo</th><th>CUIT</th><th>Contacto</th>{canWrite&&<th>Acciones</th>}</tr></thead><tbody>{rows.map(row=><tr key={row.id}><td>{row.name}</td><td>{contactRoleLabels[row.party_role]}</td><td>{row.tax_id||"-"}</td><td>{row.contact||"-"}</td>{canWrite&&<td><div className="inline-actions"><button className="small-button" onClick={()=>edit(row)}>Editar</button><button className="small-button" onClick={()=>{setArchiving(row);setMessage("")}}>Archivar</button></div></td>}</tr>)}</tbody></table></div>}
  {editing!==undefined&&<div className="modal-backdrop stacked-modal"><section className="modal" role="dialog" aria-modal="true" aria-label={editing?"Editar contacto":"Agregar contacto"}><h3>{editing?"Editar contacto":"Agregar contacto"}</h3><form className="modal-form" autoComplete="off" onSubmit={save}><fieldset className="cometa-form-fields" disabled={busy}><label>Nombre / razón social<input autoComplete="off" required maxLength={200} value={name} onChange={event=>setName(event.target.value)}/></label><label>Tipo<select aria-label="Tipo de contacto" value={role} onChange={event=>setRole(event.target.value as ContactRole)}><option value="supplier">Proveedor</option><option value="buyer">Comprador</option><option value="both">Proveedor y comprador</option></select></label><label>CUIT<input autoComplete="off" maxLength={30} value={taxId} onChange={event=>setTaxId(event.target.value)}/></label><label>Contacto<input autoComplete="off" maxLength={200} value={contact} onChange={event=>setContact(event.target.value)} placeholder="Teléfono o email"/></label></fieldset>{message&&<p className="warning-box" role="alert">{message}</p>}<div className="modal-actions"><button className="secondary-button" type="button" disabled={busy} onClick={()=>setEditing(undefined)}>Cancelar</button><button className="primary-button" disabled={busy} type="submit">{busy?"Guardando...":"Guardar contacto"}</button></div></form></section></div>}
  {archiving&&<div className="modal-backdrop stacked-modal"><section className="modal" role="dialog" aria-modal="true" aria-label="Archivar contacto"><h3>Archivar contacto</h3><p>{archiving.name}</p><p>Dejará de aparecer en las sugerencias. Los movimientos anteriores conservan sus datos.</p>{message&&<p className="warning-box" role="alert">{message}</p>}<div className="modal-actions"><button className="secondary-button" disabled={busy} onClick={()=>setArchiving(null)}>Cancelar</button><button className="primary-button" disabled={busy} onClick={archive}>{busy?"Archivando...":"Archivar contacto"}</button></div></section></div>}
 </section>;
}
