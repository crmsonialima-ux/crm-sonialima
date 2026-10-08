begin;

-- Return the original Windows-1252 byte represented by one Unicode character.
-- Keeping this mapping numeric makes the migration independent from editor encoding.
create or replace function public.crm_windows_1252_byte(p_character text)
returns integer
language plpgsql
immutable
strict
parallel safe
set search_path = pg_catalog
as $$
declare
  codepoint integer := ascii(p_character);
begin
  if codepoint between 0 and 255 then
    return codepoint;
  end if;

  return case codepoint
    when 8364 then 128
    when 8218 then 130
    when 402 then 131
    when 8222 then 132
    when 8230 then 133
    when 8224 then 134
    when 8225 then 135
    when 710 then 136
    when 8240 then 137
    when 352 then 138
    when 8249 then 139
    when 338 then 140
    when 381 then 142
    when 8216 then 145
    when 8217 then 146
    when 8220 then 147
    when 8221 then 148
    when 8226 then 149
    when 8211 then 150
    when 8212 then 151
    when 732 then 152
    when 8482 then 153
    when 353 then 154
    when 8250 then 155
    when 339 then 156
    when 382 then 158
    when 376 then 159
    else null
  end;
end;
$$;

-- Repair only byte sequences that form a valid, shorter UTF-8 character.
-- Legitimate mixed text is preserved because invalid candidates are copied as-is.
-- Three passes also repair strings that were decoded incorrectly more than once.
create or replace function public.crm_repair_utf8_mojibake(p_value text)
returns text
language plpgsql
immutable
strict
parallel safe
set search_path = public, pg_catalog
as $$
declare
  working_text text := p_value;
  repaired_text text;
  candidate_text text;
  decoded_text text;
  candidate_bytes bytea;
  first_byte integer;
  byte_value integer;
  sequence_length integer;
  text_position integer;
  byte_position integer;
  pass_number integer;
  changed boolean;
  candidate_valid boolean;
begin
  for pass_number in 1..3 loop
    repaired_text := '';
    text_position := 1;
    changed := false;

    while text_position <= char_length(working_text) loop
      first_byte := public.crm_windows_1252_byte(
        substr(working_text, text_position, 1)
      );

      sequence_length := case
        when first_byte between 194 and 223 then 2
        when first_byte between 224 and 239 then 3
        when first_byte between 240 and 244 then 4
        else 1
      end;

      if sequence_length > 1
         and text_position + sequence_length - 1 <= char_length(working_text) then
        candidate_text := substr(working_text, text_position, sequence_length);
        candidate_bytes := decode(repeat('00', sequence_length), 'hex');
        candidate_valid := true;

        for byte_position in 0..sequence_length - 1 loop
          byte_value := public.crm_windows_1252_byte(
            substr(candidate_text, byte_position + 1, 1)
          );

          if byte_value is null then
            candidate_valid := false;
            exit;
          end if;

          candidate_bytes := set_byte(candidate_bytes, byte_position, byte_value);
        end loop;

        if candidate_valid then
          begin
            decoded_text := convert_from(candidate_bytes, 'UTF8');

            if decoded_text <> candidate_text
               and char_length(decoded_text) < sequence_length then
              repaired_text := repaired_text || decoded_text;
              text_position := text_position + sequence_length;
              changed := true;
              continue;
            end if;
          exception
            when others then
              -- A failed candidate is legitimate text, not mojibake.
              null;
          end;
        end if;
      end if;

      repaired_text := repaired_text || substr(working_text, text_position, 1);
      text_position := text_position + 1;
    end loop;

    working_text := repaired_text;
    exit when not changed;
  end loop;

  return working_text;
end;
$$;

create or replace function public.crm_repair_jsonb_mojibake(p_value jsonb)
returns jsonb
language plpgsql
immutable
strict
parallel safe
set search_path = public, pg_catalog
as $$
declare
  repaired_value jsonb;
begin
  case jsonb_typeof(p_value)
    when 'string' then
      return to_jsonb(public.crm_repair_utf8_mojibake(p_value #>> '{}'));
    when 'array' then
      select coalesce(
        jsonb_agg(
          public.crm_repair_jsonb_mojibake(item.value)
          order by item.ordinality
        ),
        '[]'::jsonb
      )
      into repaired_value
      from jsonb_array_elements(p_value) with ordinality as item(value, ordinality);

      return repaired_value;
    when 'object' then
      select coalesce(
        jsonb_object_agg(
          public.crm_repair_utf8_mojibake(item.key),
          public.crm_repair_jsonb_mojibake(item.value)
        ),
        '{}'::jsonb
      )
      into repaired_value
      from jsonb_each(p_value) as item(key, value);

      return repaired_value;
    else
      return p_value;
  end case;
end;
$$;

create or replace function public.crm_normalize_notification_text_encoding()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  new.title := public.crm_repair_utf8_mojibake(new.title);
  new.body := public.crm_repair_utf8_mojibake(new.body);
  new.payload := public.crm_repair_jsonb_mojibake(new.payload);
  return new;
end;
$$;

revoke all on function public.crm_normalize_notification_text_encoding()
  from public, anon, authenticated;

drop trigger if exists crm_notification_text_encoding
  on public.crm_notification_outbox;

create trigger crm_notification_text_encoding
before insert or update on public.crm_notification_outbox
for each row execute function public.crm_normalize_notification_text_encoding();

create or replace function public.crm_normalize_agenda_text_encoding()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  new.observation := public.crm_repair_utf8_mojibake(new.observation);
  new.feedback_note := public.crm_repair_utf8_mojibake(new.feedback_note);
  new.cartorio_client_name := public.crm_repair_utf8_mojibake(new.cartorio_client_name);
  new.cartorio_property_address := public.crm_repair_utf8_mojibake(new.cartorio_property_address);
  new.cartorio_name := public.crm_repair_utf8_mojibake(new.cartorio_name);
  new.cartorio_service := public.crm_repair_utf8_mojibake(new.cartorio_service);
  new.protocol_path := public.crm_repair_utf8_mojibake(new.protocol_path);
  new.demand_client_name := public.crm_repair_utf8_mojibake(new.demand_client_name);
  new.demand_property_address := public.crm_repair_utf8_mojibake(new.demand_property_address);
  new.demand_service := public.crm_repair_utf8_mojibake(new.demand_service);
  new.source_kind := public.crm_repair_utf8_mojibake(new.source_kind);
  new.created_by_email := public.crm_repair_utf8_mojibake(new.created_by_email);
  new.protocol_paths := public.crm_repair_jsonb_mojibake(new.protocol_paths);
  new.feedback_history := public.crm_repair_jsonb_mojibake(new.feedback_history);
  new.cartorio_vitor_document_paths := public.crm_repair_jsonb_mojibake(
    new.cartorio_vitor_document_paths
  );
  new.cartorio_protocol_versions := public.crm_repair_jsonb_mojibake(
    new.cartorio_protocol_versions
  );
  return new;
end;
$$;

revoke all on function public.crm_normalize_agenda_text_encoding()
  from public, anon, authenticated;

drop trigger if exists crm_agenda_text_encoding
  on public.crm_agenda_entries;

create trigger crm_agenda_text_encoding
before insert or update on public.crm_agenda_entries
for each row execute function public.crm_normalize_agenda_text_encoding();

-- Repair persisted notification content only. Delivery fields remain untouched,
-- so delivered rows are not queued again and pending rows keep their state.
update public.crm_notification_outbox
set title = public.crm_repair_utf8_mojibake(title),
    body = public.crm_repair_utf8_mojibake(body),
    payload = public.crm_repair_jsonb_mojibake(payload)
where title is distinct from public.crm_repair_utf8_mojibake(title)
   or body is distinct from public.crm_repair_utf8_mojibake(body)
   or payload is distinct from public.crm_repair_jsonb_mojibake(payload);

-- Repair agenda text without changing schedule, ownership, milestones, or status.
update public.crm_agenda_entries
set observation = public.crm_repair_utf8_mojibake(observation),
    feedback_note = public.crm_repair_utf8_mojibake(feedback_note),
    cartorio_client_name = public.crm_repair_utf8_mojibake(cartorio_client_name),
    cartorio_property_address = public.crm_repair_utf8_mojibake(cartorio_property_address),
    cartorio_name = public.crm_repair_utf8_mojibake(cartorio_name),
    cartorio_service = public.crm_repair_utf8_mojibake(cartorio_service),
    protocol_path = public.crm_repair_utf8_mojibake(protocol_path),
    demand_client_name = public.crm_repair_utf8_mojibake(demand_client_name),
    demand_property_address = public.crm_repair_utf8_mojibake(demand_property_address),
    demand_service = public.crm_repair_utf8_mojibake(demand_service),
    source_kind = public.crm_repair_utf8_mojibake(source_kind),
    created_by_email = public.crm_repair_utf8_mojibake(created_by_email),
    protocol_paths = public.crm_repair_jsonb_mojibake(protocol_paths),
    feedback_history = public.crm_repair_jsonb_mojibake(feedback_history),
    cartorio_vitor_document_paths = public.crm_repair_jsonb_mojibake(
      cartorio_vitor_document_paths
    ),
    cartorio_protocol_versions = public.crm_repair_jsonb_mojibake(
      cartorio_protocol_versions
    )
where observation is distinct from public.crm_repair_utf8_mojibake(observation)
   or feedback_note is distinct from public.crm_repair_utf8_mojibake(feedback_note)
   or cartorio_client_name is distinct from public.crm_repair_utf8_mojibake(cartorio_client_name)
   or cartorio_property_address is distinct from public.crm_repair_utf8_mojibake(cartorio_property_address)
   or cartorio_name is distinct from public.crm_repair_utf8_mojibake(cartorio_name)
   or cartorio_service is distinct from public.crm_repair_utf8_mojibake(cartorio_service)
   or protocol_path is distinct from public.crm_repair_utf8_mojibake(protocol_path)
   or demand_client_name is distinct from public.crm_repair_utf8_mojibake(demand_client_name)
   or demand_property_address is distinct from public.crm_repair_utf8_mojibake(demand_property_address)
   or demand_service is distinct from public.crm_repair_utf8_mojibake(demand_service)
   or source_kind is distinct from public.crm_repair_utf8_mojibake(source_kind)
   or created_by_email is distinct from public.crm_repair_utf8_mojibake(created_by_email)
   or protocol_paths is distinct from public.crm_repair_jsonb_mojibake(protocol_paths)
   or feedback_history is distinct from public.crm_repair_jsonb_mojibake(feedback_history)
   or cartorio_vitor_document_paths is distinct from public.crm_repair_jsonb_mojibake(
     cartorio_vitor_document_paths
   )
   or cartorio_protocol_versions is distinct from public.crm_repair_jsonb_mojibake(
     cartorio_protocol_versions
   );

-- Audit events are intentionally immutable. Their UI applies the same display repair.
revoke all on function public.crm_windows_1252_byte(text)
  from public, anon, authenticated;
revoke all on function public.crm_repair_utf8_mojibake(text)
  from public, anon, authenticated;
revoke all on function public.crm_repair_jsonb_mojibake(jsonb)
  from public, anon, authenticated;

grant execute on function public.crm_windows_1252_byte(text) to service_role;
grant execute on function public.crm_repair_utf8_mojibake(text) to service_role;
grant execute on function public.crm_repair_jsonb_mojibake(jsonb) to service_role;

commit;
