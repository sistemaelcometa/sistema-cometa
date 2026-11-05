"use client";
import * as React from "react";
import {useActiveMembership} from "./auth-gate";
import {supabase} from "@/lib/supabase/client";
import {formatPaymentCurrency} from "@/lib/urban-payment-amounts";

type Entry={id:string;kind:"initial"|"adjustment";date:string;amount:number;currency:string|null;previousAmount:number|null;previousCurrency:string|null;registeredAt?:string};
type LeaseHistory={id:string;tenant:string;start:string;end:string;status:string;currentAmount:number;currentCurrency:string;initialSource:string;entries:Entry[]};
const dateLabel=(date:string)=>date?date.split("-").reverse().join("/"):"-";
const amountLabel=(amount:number,currency:string|null)=>currency?formatPaymentCurrency(Number(amount),currency):new Intl.NumberFormat("es-AR",{minimumFractionDigits:2,maximumFractionDigits:2}).format(Number(amount))+" (moneda no registrada)";

export function LeaseAdjustmentHistory({unit,onClose}:{unit:{id:string;name:string;building:string};onClose:()=>void}){
 const membership=useActiveMembership(),org=membership?.organization_id;
 const [leases,setLeases]=React.useState<LeaseHistory[]>([]),[selected,setSelected]=React.useState(""),[loading,setLoading]=React.useState(true),[error,setError]=React.useState("");
 React.useEffect(()=>{
  let cancelled=false;setLoading(true);setLeases([]);setError("");
  if(!org||!supabase){setLoading(false);setError("No se pudo consultar el historial.");return}
  Promise.resolve(supabase.rpc("get_urban_lease_amount_history",{target_organization_id:org,target_unit_id:unit.id})).then(({data,error:readError})=>{
   if(cancelled)return;if(readError){setError(readError.message);return}
   const list=(data??[]) as LeaseHistory[];setLeases(list);setSelected(list.find(lease=>lease.status==="Activo")?.id||list[0]?.id||"");
  }).catch(()=>{if(!cancelled)setError("No se pudo cargar el historial de actualizaciones.")}).finally(()=>{if(!cancelled)setLoading(false)});
  return()=>{cancelled=true};
 },[org,unit.id]);
 const lease=leases.find(item=>item.id===selected)||leases[0];
 return <div className="modal-backdrop stacked-modal"><section className="modal wide-modal lease-adjustment-history" role="dialog" aria-modal="true" aria-label="Historial de actualizaciones">
  <div className="section-title"><div><p className="eyebrow">{unit.building} · {unit.name}</p><h3>Historial de actualizaciones</h3></div><button className="icon-button" type="button" onClick={onClose} aria-label="Cerrar">X</button></div>
  {loading&&<p className="empty-state" role="status">Cargando historial...</p>}
  {error&&<p className="warning-box" role="alert">{error}</p>}
  {!loading&&!error&&!lease&&<p className="empty-state">Todavía no hay contratos cargados para este departamento.</p>}
  {lease&&<><label className="field">Contrato<select value={lease.id} onChange={event=>setSelected(event.target.value)}>{leases.map(item=><option key={item.id} value={item.id}>{item.tenant} · {dateLabel(item.start)} - {dateLabel(item.end)} · {item.status}</option>)}</select></label>
   <div className="lease-amount-summary"><strong>{lease.tenant}</strong><span>Importe actual registrado: <strong>{amountLabel(lease.currentAmount,lease.currentCurrency)}</strong></span></div>
   <p className="lease-amount-help">Importes registrados en el sistema.{lease.initialSource==="first_adjustment"?" El importe inicial se recuperó del primer cambio guardado.":""}</p>
   <div className="responsive-table"><table><thead><tr><th>Fecha</th><th>Concepto</th><th>Importe anterior</th><th>Importe resultante</th></tr></thead><tbody>{lease.entries.map((entry,index)=><tr key={entry.id} className={entry.kind==="initial"?"lease-initial-amount":""}><td>{dateLabel(entry.date)}</td><td>{entry.kind==="initial"?"Importe inicial registrado":"Actualización "+index}</td><td>{entry.previousAmount===null?"-":amountLabel(entry.previousAmount,entry.previousCurrency)}</td><td><strong>{amountLabel(entry.amount,entry.currency)}</strong></td></tr>)}</tbody></table></div>
   {lease.entries.length===1&&<p className="empty-state">Todavía no hay actualizaciones de monto registradas para este contrato.</p>}
  </>}
 </section></div>;
}
