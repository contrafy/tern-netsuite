/**
 * @NApiVersion 2.1
 * @NScriptType UserEventScript
 * @NModuleScope SameAccount
 *
 * {{name}} ({{scriptId}}): {{unknown}} stays as written.
 */
define(['N/log'], (log) => {
    const afterSubmit = (ctx) => log.audit({ title: '{{scriptId}}', details: ctx.type });
    return { afterSubmit };
});
