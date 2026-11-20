Class HFSplitTest.Fixture Extends HFSplit.Importer
{

/// Exercise the real importer with deterministic pages and configurable source failures.
ClassMethod Fetch(dataset, config, split, offset, length, tls, Output revision) As %DynamicObject
{
    set size=$select(tls="empty":0,1:150),revision="r1"
    if (tls="revision")&&(offset>0) { set revision="r2" }
    set rows=[],page={}
    for idx=offset:1:(offset+length-1) {
        quit:idx>=size
        set body={},item={}
        do body.%Set("value",idx,"number"),body.%Set("version",tls)
        do item.%Set("row",body),item.%Set("row_idx",idx,"number")
        if (tls="broken")&&(idx=100) { do item.%Set("truncated_cells",["value"]) }
        do rows.%Push(item)
    }
    do page.%Set("rows",rows),page.%Set("num_rows_total",size,"number")
    quit page
}
}
