update crm_financing_documents
set label = replace(label, 'Documento de identificacao', 'Documento de identificação')
where label like '%identificacao%';

update crm_financing_documents
set label = replace(label, 'Documentacao de estado civil', 'Documentação de estado civil')
where label like '%Documentacao%';

update crm_financing_documents
set label = replace(label, 'Comprovante de residencia', 'Comprovante de residência')
where label like '%residencia%';

update crm_financing_documents
set label = replace(label, 'Declaracao de Imposto de Renda', 'Declaração de Imposto de Renda')
where label like '%Declaracao%';

update crm_financing_documents
set label = replace(label, 'Documentacao do imovel', 'Documentação do imóvel')
where label like '%imovel%';

update crm_financing_documents
set label = replace(label, 'Dados bancarios vendedor', 'Dados bancários vendedor')
where label like '%bancarios%';
