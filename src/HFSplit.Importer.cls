Class HFSplit.Importer Extends %RegisteredObject
{

/// Raise a readable exception when an IRIS SQL operation fails.
ClassMethod Check(result As %SQL.StatementResult)
{
    if result.%SQLCODE<0 { throw ##class(%Exception.General).%New(result.%Message,,result.%SQLCODE) }
}

/// Read a page from the official viewer using a configured, verified TLS client.
ClassMethod Fetch(dataset, config, split, offset, length, tls, Output revision) As %DynamicObject
{
    for attempt=1:1:4 {
        set req=##class(%Net.HttpRequest).%New()
        set req.Server="datasets-server.huggingface.co",req.Https=1,req.SSLConfiguration=tls
        set req.SSLCheckServerIdentity=1,req.Timeout=45
        do req.SetParam("dataset",dataset),req.SetParam("config",config),req.SetParam("split",split)
        do req.SetParam("offset",offset),req.SetParam("length",length)
        set sc=req.Get("/rows")
        if $$$ISOK(sc) {
            set code=req.HttpResponse.StatusCode
            if code=200 { quit }
            if (attempt=4)||('$listfind($listbuild(429,500,502,503,504),+code)) {
                throw ##class(%Exception.General).%New("Viewer returned HTTP "_code)
            }
        } elseif attempt=4 { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        hang attempt
    }
    set revision=req.HttpResponse.GetHeader("X-Revision")
    quit ##class(%DynamicObject).%FromJSON(req.HttpResponse.Data)
}

/// Verify page continuity and store each row with its original zero-based index.
ClassMethod SavePage(page, offset, wanted, ByRef total, key, stmt) As %Integer
{
    set size=page.%Get("num_rows_total")
    if (page.%GetTypeOf("num_rows_total")'="number")||(size'?1.N)||(page.%Get("partial")) {
        throw ##class(%Exception.General).%New("Viewer split is incomplete")
    }
    if (total'=-1)&&(size'=total) { throw ##class(%Exception.General).%New("Split size changed") }
    set total=size,rows=page.%Get("rows")
    if page.%GetTypeOf("rows")'="array" { throw ##class(%Exception.General).%New("Missing rows") }
    set n=rows.%Size()
    if n'=$select((size-offset)<wanted:size-offset,1:wanted) {
        throw ##class(%Exception.General).%New("Unexpected page length at "_offset)
    }
    for i=0:1:n-1 {
        set item=rows.%Get(i),idx=offset+i
        if (item.%GetTypeOf("row_idx")'="number")||(item.%Get("row_idx")'=idx)||(item.%GetTypeOf("row")'="object") {
            throw ##class(%Exception.General).%New("Unexpected source row at "_idx)
        }
        if item.%IsDefined("truncated_cells") {
            if (item.%GetTypeOf("truncated_cells")'="array")||(item.%Get("truncated_cells").%Size()>0) {
                throw ##class(%Exception.General).%New("Truncated cells at "_idx)
            }
        }
        set stream=##class(%Stream.TmpCharacter).%New()
        do item.%Get("row").%ToJSON(stream)
        do stream.Rewind()
        do ..Check(stmt.%Execute(key,idx,stream))
    }
    quit n
}

/// Refresh a split atomically. A positive limit replaces only the requested prefix.
ClassMethod Import(dataset As %String, config As %String, split As %String, limit As %Integer = 0, tls As %String = "HFViewerTLS") As %Integer
{
    if (dataset="")||(config="")||(split="")||(limit'?1.N) { throw ##class(%Exception.General).%New("Invalid split or limit") }
    do ..Check(##class(%SQL.Statement).%ExecDirect(,"CREATE TABLE IF NOT EXISTS HFSplit.Sources (SourceKey VARCHAR(64) PRIMARY KEY,DatasetName VARCHAR(255),ConfigName VARCHAR(255),SplitName VARCHAR(255))"))
    do ..Check(##class(%SQL.Statement).%ExecDirect(,"CREATE TABLE IF NOT EXISTS HFSplit.Records (SourceKey VARCHAR(64) NOT NULL,SourceRow BIGINT NOT NULL,JsonBody LONGVARCHAR,PRIMARY KEY(SourceKey,SourceRow))"))
    set stmt=##class(%SQL.Statement).%New()
    set sc=stmt.%Prepare("INSERT OR UPDATE INTO HFSplit.Records (SourceKey,SourceRow,JsonBody) VALUES (?,?,?)")
    $$$ThrowOnError(sc)
    set digest=$system.Encryption.SHAHash(256,$zconvert($listbuild(dataset,config,split),"O","UTF8"))
    set key=""
    for i=1:1:$length(digest) { set key=key_$extract("0"_$zhex($ascii(digest,i)),*-1,*) }
    set level=$tlevel,offset=0,total=-1
    tstart
    try {
        // Reuse the original source key when upgrading an existing split.
        set found=##class(%SQL.Statement).%ExecDirect(,"SELECT SourceKey FROM HFSplit.Sources WHERE %EXACT(DatasetName)=? AND %EXACT(ConfigName)=? AND %EXACT(SplitName)=?",dataset,config,split)
        do ..Check(found)
        if found.%Next() { set key=found.%GetData(1) }
        do ..Check(##class(%SQL.Statement).%ExecDirect(,"INSERT OR UPDATE INTO HFSplit.Sources (SourceKey,DatasetName,ConfigName,SplitName) VALUES (?,?,?,?)",key,dataset,config,split))
        for {
            set wanted=$select((limit>0)&&((limit-offset)<100):limit-offset,1:100)
            set page=..Fetch(dataset,config,split,offset,wanted,tls,.rev)
            if offset=0 { set revision=rev } elseif rev'=revision { throw ##class(%Exception.General).%New("Viewer revision changed") }
            set offset=offset+..SavePage(page,offset,wanted,.total,key,stmt)
            quit:(offset>=total)||((limit>0)&&(offset>=limit))
        }
        if limit=0 { do ..Check(##class(%SQL.Statement).%ExecDirect(,"DELETE FROM HFSplit.Records WHERE SourceKey=? AND SourceRow>=?",key,offset)) }
        tcommit
    } catch ex {
        if $tlevel>level { trollback 1 }
        throw ex
    }
    quit offset
}

}
