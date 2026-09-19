do $$
declare
  v_old_id uuid;
  v_new_id uuid;
begin
  select id into v_old_id
  from public.tc_constitution_versions
  where public_code = 'TCCONST-0001';

  if v_old_id is null then
    raise exception 'TCCONST-0001 not found';
  end if;

  select id into v_new_id
  from public.tc_constitution_versions
  where public_code = 'TCCONST-0002';

  if v_new_id is null then
    insert into public.tc_constitution_versions (
      version_no,
      public_code,
      title,
      mission_statement,
      status,
      legal_status,
      notes,
      approved_at
    ) values (
      2,
      'TCCONST-0002',
      'Constitución de Principios de TU COMUNIDAD — Crecimiento con misión protegida',
      'TU COMUNIDAD fue creada para servir a la comunidad y no para aprovecharse de ella. Todo lo que se ofrece en la red debe sumar valor, no restarlo. La red puede crecer, expandirse, innovar, incorporar nuevas tecnologías, servicios, territorios, socios e inversión, siempre que ese crecimiento fortalezca y no sustituya, debilite ni contradiga su misión comunitaria. Crecer está permitido; desviarse del propósito no.',
      'MASTER_APPROVED',
      'PENDING',
      'Versión 2 del MASTER. Conserva íntegramente TCCONST-0001 y aclara que el crecimiento, la innovación, la expansión y la inversión son compatibles con TU COMUNIDAD únicamente cuando fortalecen su misión comunitaria. Pendiente traducción jurídica a estatutos, pactos y contratos por asesor legal competente.',
      now()
    ) returning id into v_new_id;

    insert into public.tc_constitution_principles (
      constitution_version_id,
      principle_code,
      protection_level,
      title,
      statement,
      rationale,
      sort_order,
      is_foundational
    )
    select
      v_new_id,
      principle_code,
      protection_level,
      title,
      statement,
      rationale,
      sort_order,
      is_foundational
    from public.tc_constitution_principles
    where constitution_version_id = v_old_id;

    insert into public.tc_constitution_reserved_actions (
      constitution_version_id,
      action_code,
      title,
      description,
      protection_class,
      legal_mechanism_status,
      sort_order
    )
    select
      v_new_id,
      action_code,
      title,
      description,
      protection_class,
      legal_mechanism_status,
      sort_order
    from public.tc_constitution_reserved_actions
    where constitution_version_id = v_old_id;

    insert into public.tc_constitution_principles (
      constitution_version_id,
      principle_code,
      protection_level,
      title,
      statement,
      rationale,
      sort_order,
      is_foundational
    ) values (
      v_new_id,
      'GROW_WITHOUT_MISSION_DRIFT',
      1,
      'Crecer sin cambiar de rumbo',
      'TU COMUNIDAD acepta y promueve el crecimiento, la expansión territorial, la innovación, nuevas tecnologías, nuevos servicios, nuevas alianzas, inversión responsable y nuevas oportunidades cuando estas sumen valor y fortalezcan a la comunidad. Ningún crecimiento podrá utilizarse como justificación para abandonar, sustituir, debilitar o convertir en secundaria la misión de servir a la comunidad y no aprovecharse de ella.',
      'Distingue expresamente crecimiento de desviación de misión. La red puede evolucionar en escala, tecnología, servicios y estructura, pero su propósito comunitario permanece como criterio superior.',
      25,
      true
    );

    insert into public.tc_constitution_reserved_actions (
      constitution_version_id,
      action_code,
      title,
      description,
      protection_class,
      legal_mechanism_status,
      sort_order
    ) values (
      v_new_id,
      'MISSION_COMPATIBILITY_REVIEW',
      'Revisión de compatibilidad con la misión',
      'Toda expansión, inversión, alianza, tecnología, servicio o cambio estructural de alto impacto debe evaluarse por su compatibilidad con la misión. El crecimiento que suma y fortalece a la comunidad puede avanzar por la gobernanza aplicable; el cambio que sustituya, debilite o contradiga la misión debe tratarse como cambio de misión y quedar sujeto a la protección FUNDAMENTAL correspondiente.',
      'FOUNDATIONAL',
      'PENDING',
      15
    );
  end if;
end $$;