"use client";
import * as React from "react";
import {supabase} from "@/lib/supabase/client";
import {argentinaDay} from "@/lib/argentina-day";
import {harvestLabel,storeOptionLabel,tonnes} from "@/lib/cometa-grain";
import type {GrainData} from "@/lib/cometa-grain";

export function CometaClearStock({organization,data,onClose,onSaved,onReload}:{organization:string;data:GrainData;onClose:()=>void;onSaved:()=>void;onReload:()=>void}){
 const [store,setStore]=React.useState(''),[date,setDate]=React.useState(argentinaDay),[detail,setDetail]=React.useState(''),[reference,setReference]=React.useState(''),[busy,setBusy]=React.useState(false),[error,setError]=React.useState('');
 const working=React.useRef(false),attempt=React.useRef<{signature:string;id:string}|null>(null);
 const balances=data.balances.filter(row=>row.store_id===store&&Number(row.tonnes)>0),total=balances.reduce((sum,row)=>sum+Math.round(Number(row.tonnes)*1000),0)/1000;
 const stores=data.stores.filter(item=>data.balances.some(row=>row.store_id===item.id&&Number(row.tonnes)>0));
 async function save(event:React.FormEvent){
  event.preventDefault();if(working.current||!supabase)return;
  if(!balances.length||!detail.trim()){setError('Elegí un silo con stock y completá el motivo.');return}
  const args={target_organization_id:organization,target_store_id:store,entry_date:date,expected_balances:balances.map(row=>({harvest_id:row.harvest_id,tonnes:Number(row.tonnes)})).sort((a,b)=>a.harvest_id.localeCompare(b.harvest_id)),entry_detail:detail.trim(),entry_reference:reference.trim()};
  const signature=JSON.stringify(args);if(attempt.current?.signature!==signature)attempt.current={signature,id:crypto.randomUUID()};working.current=true;setBusy(true);setError('');
  try{const result=await supabase.rpc('clear_cometa_grain_store',{...args,operation_id:attempt.current.id});if(result.error)throw result.error;onSaved()}
  catch(err){const message=(err as {message?:string}).message||'No se pudo liquidar. Podés reintentar sin duplicar la operación.';setError(message);if(/stock cambio|sin stock/i.test(message))onReload()}
  finally{working.current=false;setBusy(false)}
 }
 return <div className="modal-backdrop stacked-modal"><section className="modal wide-modal cometa-grain-modal" role="dialog" aria-modal="true" aria-label="Liquidar stock"><div className="section-title"><h3>Liquidar stock</h3><button className="icon-button" disabled={busy} onClick={onClose} aria-label="Cerrar">X</button></div><p>Da de baja todo el remanente del silo elegido y deja su saldo en cero. La fecha y el motivo quedan en el historial de grano. No registra dinero en Caja.</p><form className="modal-form" autoComplete="off" onSubmit={save}><fieldset disabled={busy} className="cometa-form-fields"><div className="form-grid"><label>Silo / silo bolsa<select aria-label="Silo a liquidar" required value={store} onChange={event=>{setStore(event.target.value);setError('')}}><option value="">Elegir almacenamiento</option>{stores.map(item=><option value={item.id} key={item.id}>{storeOptionLabel(item,data)}</option>)}</select></label><label>Fecha<input type="date" required value={date} onChange={event=>setDate(event.target.value)}/></label><label className="form-wide">Motivo<input autoComplete="off" required maxLength={200} value={detail} onChange={event=>setDetail(event.target.value)} placeholder="Ej.: remanente retirado a tolva"/></label><label className="form-wide">Referencia (opcional)<input autoComplete="off" maxLength={200} value={reference} onChange={event=>setReference(event.target.value)}/></label></div>{store&&<section className="cometa-split" aria-label="Stock a liquidar"><h4>Stock a liquidar</h4>{balances.map(row=><p key={row.harvest_id}>{harvestLabel(data.harvests.find(item=>item.id===row.harvest_id))} · <strong>{tonnes(row.tonnes)}</strong></p>)}<strong>Total: {tonnes(total)} · Saldo final: 0 t</strong></section>}</fieldset>{error&&<p className="warning-box" role="alert">{error}</p>}<div className="modal-actions"><button type="button" className="secondary-button" disabled={busy} onClick={onClose}>Cancelar</button><button type="submit" className="primary-button" disabled={busy||!balances.length}>{busy?'Liquidando...':'Confirmar liquidación'}</button></div></form></section></div>;
}
