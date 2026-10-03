CREATE OR REPLACE FUNCTION public.issue_result_snapshot(
  p_academic_year_id uuid,p_grade_level_id uuid,p_section_id uuid,p_term public.result_period,
  p_template public.result_template,p_results_count integer,p_scope text,p_snapshot jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path=public AS $$
DECLARE
  v_school uuid:=public.current_school_id(); v_id uuid; v_subject_count int; v_expected_students int;
  v_exam numeric; v_course numeric; v_pass numeric; v_terms public.score_term[];
  r jsonb; x jsonb; sid uuid; subid uuid; score numeric; complete boolean;
  total numeric; maximum numeric; pct numeric; student_complete boolean; student_passed boolean;
BEGIN
  IF v_school IS NULL OR NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'غير مصرح'; END IF;
  IF p_scope NOT IN ('section','grade') OR jsonb_typeof(p_snapshot->'results')<>'array' THEN RAISE EXCEPTION 'بيانات الإصدار غير صالحة'; END IF;
  IF p_results_count<>jsonb_array_length(p_snapshot->'results') THEN RAISE EXCEPTION 'عدد النتائج غير صحيح'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.academic_years WHERE id=p_academic_year_id AND school_id=v_school) THEN RAISE EXCEPTION 'العام الدراسي غير صالح'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.grade_levels WHERE id=p_grade_level_id AND school_id=v_school AND academic_year_id=p_academic_year_id) THEN RAISE EXCEPTION 'الصف غير صالح'; END IF;
  IF p_scope='section' AND NOT EXISTS(SELECT 1 FROM public.sections WHERE id=p_section_id AND school_id=v_school AND grade_level_id=p_grade_level_id) THEN RAISE EXCEPTION 'الشعبة غير صالحة'; END IF;
  SELECT exam_max,coursework_max,pass_mark INTO v_exam,v_course,v_pass FROM public.schools WHERE id=v_school;
  SELECT count(*) INTO v_subject_count FROM public.subjects WHERE school_id=v_school AND grade_level_id=p_grade_level_id;
  SELECT count(*) INTO v_expected_students FROM public.student_enrollments e WHERE e.school_id=v_school AND e.academic_year_id=p_academic_year_id AND e.grade_level_id=p_grade_level_id AND (p_scope='grade' OR e.section_id=p_section_id);
  IF v_subject_count=0 OR p_results_count<>v_expected_students THEN RAISE EXCEPTION 'بيانات الطلاب أو المواد غير مكتملة'; END IF;
  v_terms:=CASE WHEN p_term='final' THEN ARRAY['first','second']::public.score_term[] ELSE ARRAY[p_term::text]::public.score_term[] END;

  FOR r IN SELECT value FROM jsonb_array_elements(p_snapshot->'results') LOOP
    sid:=(r->'student'->>'id')::uuid;
    IF NOT EXISTS(SELECT 1 FROM public.student_enrollments e WHERE e.school_id=v_school AND e.academic_year_id=p_academic_year_id AND e.grade_level_id=p_grade_level_id AND e.student_id=sid AND (p_scope='grade' OR e.section_id=p_section_id)) THEN
      RAISE EXCEPTION 'الطالب لا ينتمي إلى نطاق النتيجة';
    END IF;
    IF jsonb_typeof(r->'subjectScores')<>'array' OR jsonb_array_length(r->'subjectScores')<>v_subject_count THEN RAISE EXCEPTION 'مواد الطالب غير مكتملة'; END IF;
    total:=0; student_complete:=true; student_passed:=true;
    FOR x IN SELECT value FROM jsonb_array_elements(r->'subjectScores') LOOP
      subid:=(x->'subject'->>'id')::uuid;
      IF NOT EXISTS(SELECT 1 FROM public.subjects WHERE id=subid AND school_id=v_school AND grade_level_id=p_grade_level_id) THEN RAISE EXCEPTION 'مادة غير صالحة'; END IF;
      SELECT COALESCE(sum(COALESCE(s.exam_score,0)+COALESCE(s.coursework_score,0)),0),
             count(*)=array_length(v_terms,1) AND bool_and(s.exam_score IS NOT NULL AND s.coursework_score IS NOT NULL)
      INTO score,complete FROM public.scores s
      WHERE s.school_id=v_school AND s.academic_year_id=p_academic_year_id AND s.student_id=sid AND s.subject_id=subid AND s.term=ANY(v_terms);
      complete:=COALESCE(complete,false); total:=total+score; student_complete:=student_complete AND complete; student_passed:=student_passed AND complete AND score>=v_pass*array_length(v_terms,1);
      IF (x->>'score')::numeric IS DISTINCT FROM score OR (x->>'complete')::boolean IS DISTINCT FROM complete OR (x->>'passed')::boolean IS DISTINCT FROM (complete AND score>=v_pass*array_length(v_terms,1)) THEN RAISE EXCEPTION 'درجة مادة لا تطابق البيانات المحفوظة'; END IF;
    END LOOP;
    IF NOT student_complete THEN student_passed:=false; END IF;
    maximum:=(v_exam+v_course)*array_length(v_terms,1)*v_subject_count;
    pct:=CASE WHEN maximum>0 THEN total/maximum*100 ELSE 0 END;
    IF (r->>'total')::numeric IS DISTINCT FROM total OR (r->>'maximum')::numeric IS DISTINCT FROM maximum
       OR abs((r->>'percentage')::numeric-pct)>0.0001 OR (r->>'complete')::boolean IS DISTINCT FROM student_complete
       OR (r->>'passed')::boolean IS DISTINCT FROM student_passed THEN RAISE EXCEPTION 'بيانات النتيجة لا تطابق الحسابات الأصلية'; END IF;
  END LOOP;

  INSERT INTO public.result_issuances(school_id,academic_year_id,grade_level_id,section_id,term,template,results_count,issued_by,scope,snapshot)
  VALUES(v_school,p_academic_year_id,p_grade_level_id,p_section_id,p_term,p_template,p_results_count,auth.uid(),p_scope,p_snapshot) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.issue_result_snapshot(uuid,uuid,uuid,public.result_period,public.result_template,integer,text,jsonb) TO authenticated;