SELECT 
    item.value,
    l.url,
    p.effname,
    p.origversion,
    p.rawversion,
    p.version,
    p.versionclass
FROM packages p
CROSS JOIN LATERAL json_array_elements(p.links) AS elem(value)
CROSS JOIN LATERAL json_array_elements(elem.value) WITH ORDINALITY AS item(value, pos)
JOIN links l ON l.id = (item.value #>> '{}')::integer
WHERE item.pos = 2
LIMIT 10;

--

SELECT 
    (elem.value ->> 0)::integer AS link_type,
    l.url,
    p.repo,
    p.effname,
    p.rawversion,
    p.version,
    p.versionclass
FROM packages p
CROSS JOIN LATERAL json_array_elements(p.links) AS elem(value)
JOIN links l ON l.id = (elem.value ->> 1)::integer
WHERE (elem.value ->> 0)::integer = 1 or (elem.value ->> 0)::integer = 2

--

SELECT 
    (elem.value ->> 0)::integer AS link_type,
    l.url,
    p.repo,
    p.effname,
    p.rawversion,
    p.versionclass
FROM packages p
CROSS JOIN LATERAL json_array_elements(p.links) AS elem(value)
JOIN links l ON l.id = (elem.value ->> 1)::integer
WHERE (NOT p.shadow='t') AND ((elem.value ->> 0)::integer = 1 or (elem.value ->> 0)::integer = 2)
LIMIT 10;

--

COPY (SELECT 
    (elem.value ->> 0)::integer AS link_type,
    l.url,
    p.repo,
    p.effname,
    p.rawversion,
    p.versionclass
FROM packages p
CROSS JOIN LATERAL json_array_elements(p.links) AS elem(value)
JOIN links l ON l.id = (elem.value ->> 1)::integer
WHERE (NOT p.shadow='t') AND ((elem.value ->> 0)::integer = 1 or (elem.value ->> 0)::integer = 2)) TO '/workspaces/GeneralMetadata.jl/out.csv' WITH (format csv);
