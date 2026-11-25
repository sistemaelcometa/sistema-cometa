"use client";
import * as React from "react";
import {supabase} from "@/lib/supabase/client";
import {storeLabel} from "@/lib/cometa-grain";
import type {GrainStore} from "@/lib/cometa-grain";

export function CometaDeleteBag({organization,store,onClose,onSaved}:{organization:string;store:GrainStore;onClose:()=>void;onSaved:()=>void}){
 const [busy,setBusy]=React.useState(false),[error,setError]=React.useState('');
 const working=React.useRef(false);
 async function remove(){
  if(working.current||!supabase)return;working.current=true;setBusy(true);setError('');
  try{const result=await supabase.rpc('delete_cometa_empty_bag',{target_organization_id:organization,target_store_id:store.id});if(result.error)throw result.error;onSaved()}
  catch(err){setError((err as {message?:string}).message||'No se pudo eliminar la bolsa. Podés reintentar.')}
  finally{working.current=false;setBusy(false)}
 }
 return <div className="modal-backdrop stacked-modal"><section className="modal" role="dialog" aria-modal="true" aria-label="Eliminar silo bolsa"><h3>Eliminar silo bolsa</h3><p><strong>{storeLabel(store)}</strong></p><p>Se quitará de Acopio y de los destinos disponibles de Cosecha. Sus movimientos anteriores quedarán conservados en el historial.</p>{error&&<p className="warning-box" role="alert">{error}</p>}<div className="modal-actions"><button className="secondary-button" disabled={busy} onClick={onClose}>Cancelar</button><button className="primary-button danger-confirm-button" disabled={busy} onClick={remove}>{busy?'Eliminando...':'Eliminar bolsa'}</button></div></section></div>;
}
