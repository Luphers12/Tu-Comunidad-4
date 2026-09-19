do $$
declare
  v_language_id uuid;
  v_variant_id uuid;
  v_template_id uuid;
begin
  select id into v_language_id from public.languages where public_id='LAN-0008' and iso_code='cac' limit 1;
  select id into v_variant_id from public.language_variants where public_id='LVAR-0001' and language_id=v_language_id limit 1;

  if v_language_id is null or v_variant_id is null then
    raise exception 'Chuj San Mateo Ixtatan language/variant not found';
  end if;

  select id into v_template_id from public.linguistic_assessment_templates where template_code='CHUJ_SMI_ENTRY_V1' limit 1;

  if v_template_id is null then
    insert into public.linguistic_assessment_templates(
      template_code, language_id, variant_id, title, description, version, status,
      minimum_independent_reviews, allow_ai_assistance, legal_status, cultural_status, safety_status
    ) values (
      'CHUJ_SMI_ENTRY_V1', v_language_id, v_variant_id,
      'Evaluación de ingreso — Chuj, San Mateo Ixtatán',
      'Piloto de ingreso para evaluar capacidades lingüísticas de hablantes de Chuj variante San Mateo Ixtatán. No contiene respuestas modelo en Chuj; requiere evaluación humana independiente por hablantes/verificadores autorizados.',
      1, 'DRAFT', 2, false, 'PENDING', 'PENDING', 'PENDING'
    ) returning id into v_template_id;
  end if;

  insert into public.linguistic_assessment_template_items
    (template_id,item_order,competency,prompt_type,source_text,prompt_text,context_note,rubric,max_score,is_required)
  values
    (v_template_id,1,'TRANSLATE','TRANSLATION','Buenos días. ¿Cómo está usted?','Traduzca esta frase al Chuj de San Mateo Ixtatán tal como la diría naturalmente en su comunidad.','Evaluar naturalidad, significado y adecuación a la variante. No exigir una única forma si existen variantes legítimas.',jsonb_build_object('criteria',jsonb_build_array('meaning_preserved','variant_fit','naturalness'),'human_validation_required',true),5,true),
    (v_template_id,2,'TRANSLATE','TRANSLATION','Necesito ir al centro de la comunidad.','Traduzca esta frase al Chuj de San Mateo Ixtatán.','Contexto cotidiano de orientación/localidad.',jsonb_build_object('criteria',jsonb_build_array('meaning_preserved','local_usage','clarity'),'human_validation_required',true),5,true),
    (v_template_id,3,'TRANSLATE','TRANSLATION','El paquete llegó al punto de entrega.','Traduzca esta frase para una interfaz de TU COMUNIDAD.','Contexto logístico. Revisar que la frase sea comprensible para usuarios locales.',jsonb_build_object('criteria',jsonb_build_array('meaning_preserved','ui_clarity','terminology_consistency'),'human_validation_required',true),5,true),
    (v_template_id,4,'UNDERSTAND','TEXT_RESPONSE',null,'Explique en español qué diferencias de uso o pronunciación considera importantes entre el Chuj de San Mateo Ixtatán y otras formas de Chuj que conozca.','No se requiere conocimiento académico; se evalúa conciencia de variante y experiencia real. No penalizar a quien solo conozca su propia variante.',jsonb_build_object('criteria',jsonb_build_array('variant_awareness','honesty_about_scope','community_experience'),'human_validation_required',true),4,true),
    (v_template_id,5,'WRITE','TEXT_RESPONSE',null,'Escriba en Chuj de San Mateo Ixtatán una frase breve que usaría para dar la bienvenida a una persona de su comunidad. Después explique en español qué significa.','La respuesta en Chuj debe conservarse exactamente como la persona la escribe; no normalizar automáticamente.',jsonb_build_object('criteria',jsonb_build_array('written_fluency','meaning_explanation','variant_fit'),'preserve_exact_text',true,'human_validation_required',true),5,true),
    (v_template_id,6,'ORTHOGRAPHY','CORRECTION',null,'Escriba un ejemplo de una palabra o frase en Chuj que frecuentemente vea escrita de más de una manera. Explique cuál forma usa usted y por qué.','No presentar una forma como normativa sin evidencia. Sirve para evaluar conciencia ortográfica y variación.',jsonb_build_object('criteria',jsonb_build_array('orthographic_awareness','explanation_quality','variant_sensitivity'),'human_validation_required',true),4,true),
    (v_template_id,7,'REVIEW','CONTEXT_JUDGMENT',null,'Imagine que otra persona tradujo una frase correctamente en significado, pero la expresión suena de otra variante de Chuj. ¿Qué haría antes de aprobarla para San Mateo Ixtatán?','Se espera que identifique la necesidad de revisión de variante y que no cambie contenido sin trazabilidad.',jsonb_build_object('criteria',jsonb_build_array('independent_review_reasoning','variant_protection','audit_mindset'),'human_validation_required',true),4,true),
    (v_template_id,8,'CULTURAL_VALIDATE','CONTEXT_JUDGMENT',null,'Si una traducción es gramaticalmente correcta pero una expresión puede resultar irrespetuosa o inadecuada en la comunidad, explique cómo la revisaría.','Evaluar sensibilidad cultural sin asumir que una sola persona representa toda la comunidad.',jsonb_build_object('criteria',jsonb_build_array('cultural_sensitivity','consultation_awareness','non_authoritarian_reasoning'),'human_validation_required',true),4,true),
    (v_template_id,9,'VOICE','AUDIO_RESPONSE',null,'Grabe, si desea participar en tareas de voz, una presentación breve en Chuj de San Mateo Ixtatán y después diga en español qué expresó.','La grabación solo puede utilizarse para evaluación interna mientras los permisos de voz/publicación sigan pendientes.',jsonb_build_object('criteria',jsonb_build_array('spoken_fluency','variant_fit','clarity'),'optional_for_general_translation',true,'voice_rights_separate',true,'human_validation_required',true),5,false),
    (v_template_id,10,'TRANSCRIBE','TEXT_RESPONSE',null,'Si se le proporciona posteriormente un audio corto en Chuj, deberá escribir exactamente lo que escucha y marcar cualquier parte que no comprenda. Por ahora confirme si desea ser evaluado también como transcriptor.','Elemento preparatorio; no se proporciona audio en este piloto hasta aprobar la política de retención y consentimiento.',jsonb_build_object('criteria',jsonb_build_array('scope_acknowledgement'),'audio_not_yet_required',true,'human_validation_required',true),1,false),
    (v_template_id,11,'TERMINOLOGY','TEXT_RESPONSE',null,'Mencione hasta tres términos de comercio, transporte, educación o vida comunitaria que considere importante traducir con cuidado al Chuj de San Mateo Ixtatán. Explique por qué.','No convertir propuestas personales en términos oficiales sin validación independiente.',jsonb_build_object('criteria',jsonb_build_array('terminology_awareness','context_awareness','community_relevance'),'human_validation_required',true),4,true),
    (v_template_id,12,'UI_QA','CONTEXT_JUDGMENT','Entregado','Si esta palabra aparece como estado de un pedido en una aplicación, explique qué información necesitaría antes de decidir la mejor traducción al Chuj.','Evaluar comprensión de contexto UI: quién entrega, qué se entregó, estado final y espacio disponible.',jsonb_build_object('criteria',jsonb_build_array('context_questions','ui_reasoning','avoid_literal_guessing'),'human_validation_required',true),4,true)
  on conflict (template_id,item_order) do nothing;
end $$;