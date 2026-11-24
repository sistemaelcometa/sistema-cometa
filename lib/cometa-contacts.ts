export type ContactRole='supplier'|'buyer'|'both';
export type CometaContact={id:string;name:string;tax_id:string;contact:string;party_role:ContactRole};
export const contactRoleLabels:Record<ContactRole,string>={supplier:'Proveedor',buyer:'Comprador',both:'Proveedor y comprador'};
export function contactsForMovement(contacts:CometaContact[],kind:'income'|'expense'){
 const role=kind==='income'?'buyer':'supplier';
 return contacts.filter(contact=>contact.party_role===role||contact.party_role==='both');
}
