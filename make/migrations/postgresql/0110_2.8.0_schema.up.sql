/* remove the redundant data from table artifact_blob */
delete from artifact_blob afb where not exists (select digest from blob b where b.digest = afb.digest_af);

/* replace subject_artifact_id with subject_artifact_digest*/
alter table artifact_accessory add column subject_artifact_digest varchar(1024);

DO $$
DECLARE
    acc RECORD;
    art RECORD;
BEGIN
    FOR acc IN SELECT * FROM artifact_accessory
    LOOP
        SELECT * INTO art from artifact where id = acc.subject_artifact_id;
        UPDATE artifact_accessory SET subject_artifact_digest=art.digest WHERE subject_artifact_id = art.id;
    END LOOP;
END $$;

alter table artifact_accessory drop CONSTRAINT artifact_accessory_subject_artifact_id_fkey;
alter table artifact_accessory drop CONSTRAINT unique_artifact_accessory;
alter table artifact_accessory add CONSTRAINT unique_artifact_accessory UNIQUE (artifact_id, subject_artifact_digest);
alter table artifact_accessory drop column subject_artifact_id;

/* Update the registry and replication policy associated with the chartmuseum */
UPDATE registry
SET description = 'Chartmuseum has been deprecated in Harbor v2.8.0, please delete this registry.'
WHERE type in ('artifact-hub', 'helm-hub');
WITH filter_objects AS (
    SELECT id, jsonb_array_elements(filters::jsonb) AS filter
    FROM replication_policy
    WHERE filters IS NOT NULL AND filters != ''
    AND jsonb_typeof(CAST(filters AS jsonb)) = 'array'
),
replication_policy_ids AS (
    SELECT rp.id
    FROM registry r
    INNER JOIN replication_policy rp ON (rp.dest_registry_id = r.id OR rp.src_registry_id = r.id)
    WHERE r.type IN ('artifact-hub', 'helm-hub')
)
UPDATE replication_policy AS rp
SET enabled = false,
    filters = (
        SELECT COALESCE(jsonb_agg(fo.filter)::text, '')
        FROM filter_objects AS fo
        WHERE fo.id = rp.id AND NOT(filter ->> 'type' = 'resource' AND filter ->> 'value' = 'chart')
    ),
    description = 'Chartmuseum is deprecated in Harbor v2.8.0, because the Source resource filter of this rule is chart(chartmuseum), so please update this rule.'
WHERE id IN (
    SELECT id FROM filter_objects WHERE (filter ->> 'type' = 'resource' AND filter ->> 'value' = 'chart')
    UNION
    SELECT id FROM replication_policy_ids
);
/* Update the role permission and permission policy associated with the chartmuseum */
DELETE FROM role_permission
WHERE permission_policy_id IN (
    SELECT id FROM permission_policy WHERE resource IN ('helm-chart', 'helm-chart-version' ,'helm-chart-version-label')
);

DELETE FROM permission_policy
WHERE resource IN ('helm-chart', 'helm-chart-version' ,'helm-chart-version-label');
/* Update the notification policy associated with the chartmuseum */
WITH event_type_objects AS (
    SELECT id, jsonb_array_elements(event_types::jsonb) as event_type
    FROM notification_policy
    WHERE event_types IS NOT NULL AND event_types != ''
    AND jsonb_typeof(CAST(event_types AS jsonb)) = 'array'
)
UPDATE notification_policy AS np
SET event_types = (
    SELECT COALESCE(jsonb_agg(eto.event_type), '[]')
    FROM event_type_objects AS eto
    WHERE eto.id = np.id
    AND NOT(event_type @> '"UPLOAD_CHART"'::jsonb OR event_type @> '"DOWNLOAD_CHART"'::jsonb OR event_type @> '"DELETE_CHART"'::jsonb)
)
WHERE id IN (
    SELECT id FROM event_type_objects WHERE (event_type @> '"UPLOAD_CHART"'::jsonb OR event_type @> '"DOWNLOAD_CHART"'::jsonb OR event_type @> '"DELETE_CHART"'::jsonb)
);

UPDATE notification_policy
SET enabled = false,
    description = 'Chartmuseum is deprecated in Harbor v2.8.0, because this notification policy only has event type about Chartmuseum, so please update or delete this notification policy.'
WHERE event_types = '[]';

/* migrate the webhook job to execution and task as the webhook refactor since v2.8 */
DO $$
DECLARE
    job_group RECORD;
    job RECORD;
    vendor_type varchar;
    new_status varchar;
    status_code integer;
    exec_id integer;
    extra_attrs json;
BEGIN
    FOR job_group IN SELECT DISTINCT policy_id,event_type FROM notification_job WHERE event_type NOT IN ('UPLOAD_CHART', 'DOWNLOAD_CHART', 'DELETE_CHART')
    LOOP
        SELECT * INTO job FROM notification_job WHERE
        policy_id=job_group.policy_id
        AND event_type=job_group.event_type
        AND status IN ('stopped', 'finished', 'error')
        ORDER BY creation_time DESC LIMIT 1;
        /* convert vendor type */
        IF job.notify_type = 'http' THEN
            vendor_type = 'WEBHOOK';
        ELSIF job.notify_type = 'slack' THEN
            vendor_type = 'SLACK';
        ELSE
            vendor_type = 'WEBHOOK';
        END IF;
        /* convert status */
        IF job.status = 'stopped' THEN
            new_status = 'Stopped';
            status_code = 3;
        ELSIF job.status = 'error' THEN
            new_status = 'Error';
            status_code = 3;
        ELSIF job.status = 'finished' THEN
            new_status = 'Success';
            status_code = 3;
        ELSE
            new_status = '';
            status_code = 0;
        END IF;

        SELECT format('{"event_type": "%s", "payload": %s}', job.event_type, to_json(job.job_detail)::TEXT)::JSON INTO extra_attrs;
        INSERT INTO execution (vendor_type,vendor_id,status,trigger,extra_attrs,start_time,end_time,update_time) VALUES (vendor_type,job.policy_id,new_status,'EVENT',extra_attrs,job.creation_time,job.update_time,job.update_time) RETURNING id INTO exec_id;
        INSERT INTO task (execution_id,job_id,status,status_code,run_count,creation_time,start_time,update_time,end_time,vendor_type) VALUES (exec_id,job.job_uuid,new_status,status_code,1,job.creation_time,job.update_time,job.update_time,job.update_time,vendor_type);
    END LOOP;
END $$;
/* drop the old notification_job table */
DROP TABLE IF EXISTS notification_job;






