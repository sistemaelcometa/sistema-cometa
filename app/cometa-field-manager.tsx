"use client";
import * as React from "react";
import {supabase} from "@/lib/supabase/client";
import type {GrainField} from "@/lib/cometa-grain";

export function CometaFieldManager({organization,fields,canWrite,loading,onAdd,onEdit,onChanged,onClose}:{organization:string;fields:GrainField[];canWrite:boolean;loading:boolean;onAdd:()=>void;onEdit:(field:GrainField)=>void;onChanged:()=>void;onClose:()=>void}){
 const [removing,setRemoving]=React.useState<GrainField|null>(null),[busy,setBusy]=React.useState(false),[error,setError]=React.useState('');
 const working=React.useRef(false);
 async function remove(){
  if(!supabase||!removing||working.current)return;working.current=true;setBusy(true);setError('');
  try{const {error}=await supabase.rpc('delete_cometa_field',{target_organization_id:organization,target_field_id:removing.id});if(error)throw error;setRemoving(null);onChanged()}
  catch(err){setError((err as {message?:string}).message||'No se pudo eliminar el lote.')}
  finally{working.current=false;setBusy(false)}
 }
 return <><div className="modal-backdrop stacked-modal"><section className="modal wide-modal" role="dialog" aria-modal="true" aria-label="Lotes"><div className="section-title"><h3>Lotes</h3><button className="icon-button" disabled={busy} onClick={onClose} aria-label="Cerrar lotes">X</button></div>{canWrite&&<div className="inline-actions"><button className="secondary-button" disabled={busy||loading} onClick={onAdd}>Agregar lote</button></div>}{loading?<p role="status">Actualizando lotes...</p>:fields.length===0?<p className="empty-state">Agregá el primer lote para registrar cosechas.</p>:<div className="cometa-lot-list cometa-manager-list">{fields.map(field=><div key={field.id}><strong>{field.name}</strong>{canWrite&&<div className="inline-actions"><button className="small-button" disabled={busy} onClick={()=>onEdit(field)}>Editar</button><button className="small-button danger-icon-button" disabled={busy} onClick={()=>{setRemoving(field);setError('')}}>Eliminar</button></div>}</div>)}</div>}</section></div>
 {removing&&<div className="modal-backdrop stacked-modal"><section className="modal" role="dialog" aria-modal="true" aria-label="Eliminar lote"><h3>Eliminar lote</h3><p>{removing.name}</p><p>Se quitará de la lista de lotes disponibles. Sus cosechas anteriores y las existencias de grano se conservarán.</p>{error&&<p className="warning-box" role="alert">{error}</p>}<div className="modal-actions"><button className="secondary-button" disabled={busy} onClick={()=>setRemoving(null)}>Cancelar</button><button className="primary-button" disabled={busy} onClick={remove}>{busy?'Eliminando...':'Eliminar lote'}</button></div></section></div>}</>;
}
