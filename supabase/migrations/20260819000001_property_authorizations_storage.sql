-- 1. Create Private Bucket (se nao existir)
INSERT INTO storage.buckets (id, name, public)
VALUES ('property-authorizations', 'property-authorizations', false)
ON CONFLICT (id) DO NOTHING;

-- 2. SELECT para todo o bucket
CREATE POLICY "property_auth_select"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'property-authorizations' AND
  public.can_access_property_authorization(split_part(name, '/', 1), auth.uid())
);

-- 3. INSERT de PDF
CREATE POLICY "property_auth_insert_pdf"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'property-authorizations' AND
  split_part(name, '/', 2) = 'pdfs' AND
  right(lower(name), 4) = '.pdf' AND
  lower(coalesce(metadata->>'mimetype', '')) = 'application/pdf' AND
  EXISTS (
    SELECT 1 FROM public.crm_property_authorization_pdfs
    WHERE storage_path = name
      AND generated_by = auth.uid()
      AND status = 'RESERVED'
  )
);

-- 4. INSERT de documentos originais (Não-PDFs) apenas na fase PENDING para o submitted_by (Upload Session), ou Allyson a qualquer momento
CREATE POLICY "property_auth_insert_original"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'property-authorizations' AND
  split_part(name, '/', 2) != 'pdfs' AND (
    (
      EXISTS (
        SELECT 1 FROM public.crm_property_authorizations a
        WHERE a.property_id = split_part(name, '/', 1)
        AND a.submitted_by = auth.uid()
        AND a.initial_documents_finalized_at IS NULL
      )
    ) OR (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'admin' AND email ilike 'crmsoniaallyson@gmail.com'
      )
    )
  )
);

-- 5. UPDATE/DELETE de documentos originais APENAS Allyson
CREATE POLICY "property_auth_update_original"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'property-authorizations' AND
  split_part(name, '/', 2) != 'pdfs' AND
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin' AND email ilike 'crmsoniaallyson@gmail.com'
  )
);

CREATE POLICY "property_auth_delete_original"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'property-authorizations' AND
  split_part(name, '/', 2) != 'pdfs' AND
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin' AND email ilike 'crmsoniaallyson@gmail.com'
  )
);
