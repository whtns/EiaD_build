'''
config file:
    sampleFile: tab seperated file  containing sample info
    refFasta_url: link to refernece fastq_path
    salmon_version:
    sratoolkit_version:
notes:
-the 5.2 version requires specifying directorys in output section of rule iwth directory(). Biowulf currently using 5.1
-need to make a rule to download all Gencode refs

***IF YOU CHANGE A RULE NAME MAKE SURE TO CHECK cluster.json ****
Things to do
-rewrite sonneson_low_usage
-rewrite script for removing_tx
'''
import subprocess as sp
import itertools as it

def readSampleFile(samplefile):
    # returns a dictionary of dictionaries where first dict key is sample id and second dict key are sample  properties
    res={}
    with open(samplefile) as file:
        for line in file:
            info=line.strip('\n').split('\t')
            res[info[0]]={'files':info[1].split(','),'paired':True if info[2]=='y' else False, 'tissue':info[3],'subtissue':info[4]}
    return(res)

def lookupRunfromID(card,sample_dict):
    id=card
    if 'E-MTAB' in card: #not the best but it works
        return('bam_files/{}.bam'.format(id[:-2]))
    else:
        if '_' in id:
            i= '1' if id[-1]=='1' else '2'# check L/R file
            id=card[:-2]
        fqpfiles=sample_dict[id]['files']
        res=[]
        for file in fqpfiles:
            if sample_dict[id]['paired']:
                #PE
                res.append('fastqParts/{}_{}.fastq.gz'.format(file,i))
            else:
                #SE
                res.append('fastqParts/{}.fastq.gz'.format(file))
    return(res)


def all_fastqs(samp_dict):
    res=[]
    for sample in samp_dict.keys():
        if samp_dict[sample]['paired']:
            res.append('fastq_files/{}_1.fastq.gz'.format(sample))
            res.append('fastq_files/{}_2.fastq.gz'.format(sample))
        else:
            res.append('fastq_files/{}.fastq.gz'.format(sample))
    return(res)
# def samples_for_salmon(sample, sample_dict):
#     if 'E-MTAB' in sample :
#         return('{}.bam'.format(sample))
#     else:
#         if sample_dict[sample]['paired']:
#             return(['fastq_files/{}_1.fastq.gz'.format(sample),('fastq_files/{}_2.fastq.gz'.format(sample))])
#         else:
#             return('fastq_files/{}.fastq.gz'.format(sample))
#

configfile:'config.yaml'
sample_dict=readSampleFile(config['sampleFile'])# sampleID:dict{path,paired,metadata}
# need to add something to yaml for subtissues
#subtissue=["Retina_Adult.Tissue",  "RPE_Cell.Line", "ESC_Stem.Cell.Line", "RPE_Adult.Tissue"]
subtissues_SE=["RPE_Stem.Cell.Line","RPE_Cell.Line","Retina_Adult.Tissue","RPE_Fetal.Tissue","ESC_Stem.Cell.Line","Cornea_Adult.Tissue","Cornea_Fetal.Tissue","Cornea_Cell.Line","Retina_Stem.Cell.Line",'body']
subtissues_PE=["Retina_Adult.Tissue", "RPE_Cell.Line", "ESC_Stem.Cell.Line" , "RPE_Adult.Tissue",'body' ]# add body back in  at some point
tissues=['Retina','RPE','ESC','Cornea','body']
# tissues=['Retina','RPE','Pancreas','body']
# subtissues_PE=['Retina_Adult.Tissue','.Pancreas.']
# subtissues_SE=['RPE_Stem.Cell.Line','RPE_Cell.Line']
sample_names=sample_dict.keys()
loadSRAtk="module load {} && ".format(config['sratoolkit_version'])
loadSalmon= "module load {} && ".format(config['salmon_version'])
salmonindex='ref/salmonindex'
salmonindex_trimmed='ref/salmonindex_trimmed'
STARindex='ref/STARindex'
ref_fasta='ref/gencodeRef.fa'
ref_GTF='ref/gencodeAno.gtf'
ref_GTF_basic='ref/gencodeAno_bsc.gtf'
ref_GTF_PA='ref/gencodeAno_pa.gtf'
ref_PA='ref/gencodePA.fa'
badruns='badruns'
ref_trimmed='ref/gencodeRef_trimmed.fa'

rule all:
    input:'results/diffexp_efit.Rdata'
    #,'smoothed_filtered_tpms.csv'
'''
****PART 1**** download files
-still need to add missing fastq files
-gffread needs indexed fasta
-need to add versioning of tools to yaml
- the gencode pc tx has ~40k tx not in the gencode basic gtf, i looked and all the missing ones are not protein coding,
so we're gonna remove the tx  not in the gtf from the fasta
'''
rule downloadGencode:
    output:ref_fasta,ref_GTF_basic,ref_PA
    shell:
        '''

        wget -O ref/gencodeRef_tmp.fa.gz {config[refFasta_url]}
        wget -O ref/gencodeAno_bsc.gtf.gz {config[refGTF_basic_url]}
        wget -O ref/gencodePA_tmp.fa.gz {config[refPA_url]}
        gunzip ref/gencodeRef_tmp.fa.gz
        gunzip ref/gencodeAno_bsc.gtf.gz
        gunzip ref/gencodePA_tmp.fa.gz
        module load python/3.6
        python3 scripts/extract_fasta_names.py > ref/tx_names
        grep -o -Ff ref/tx_names ref/gencodeAno_bsc.gtf | grep -v -Ff - ref/tx_names > ref/tx_not_in_gtf
        python3 scripts/filterFasta.py ref/gencodePA_tmp.fa ref/chroms_to_remove ref/gencodePA.fa
        python3 scripts/filterFasta.py ref/gencodeRef_tmp.fa tx ref/tx_not_in_gtf ref/gencodeRef.fa
        rm ref/gencodeRef_tmp.fa
        rm ref/gencodePA_tmp.fa
        module load samtools
        samtools faidx ref/gencodePA.fa

        '''

rule getFQP:
    output: temp('fastqParts/{id}.fastq.gz')
    run:
        id=wildcards.id
        id=id[:-2] if '_'in id else id #idididid
        try:
            sp.check_output(loadSRAtk + 'fastq-dump --gzip --split-3 -O fastqParts {}'.format(id),shell=True)
        except sp.CalledProcessError:
            with open('logs/{}.fqp'.format(wildcards.id)) as l:
                l.write('{} did not download'.format(wildcards.id))

rule aggFastqsPE:
    input:lambda wildcards:lookupRunfromID(wildcards.sampleID,sample_dict)
    output:'fastq_files/{sampleID}.fastq.gz'
    run:
        #this can use some cleaning up - rule runs twice for paired
        id=wildcards.sampleID
        if '.bam' in input[0]:
            id=wildcards.sampleID[:-2]
            #need to collate a bam before you can convert, otherwise will lose many reads
            cmd='module load samtools &&  samtools collate -O {} | \
            samtools fastq -1 fastq_files/{}_1.fastq -2 fastq_files/{}_2.fastq -0 /dev/null -s /dev/null -n -F 0x900 -'.format(input[0],id,id)
            sp.run(cmd,shell=True)
            gunzip=' gunzip -c -f fastq_files/{}_1.fastq > fastq_files/{}_1.fastq.gz'.format(id,id)
            sp.run(gunzip,shell=True)
            gunzip=' gunzip -c -f fastq_files/{}_2.fastq > fastq_files/{}_2.fastq.gz'.format(id, id)
            sp.run(gunzip,shell=True)
        else:
            fileParts=lookupRunfromID(id,sample_dict)
            i='1' if '_' in id and id[-1]=='1' else '2'# which strand
            id=id[:-2] if '_' in id else id
            for fqp in fileParts:
                if sample_dict[id]['paired']:
                    sp.run('cat {fqp} >> fastq_files/{id}_{i}.fastq.gz '.format(fqp=fqp,i=i,id=id),shell=True)
                else:
                    sp.run('cat {fqp} >> fastq_files/{id}.fastq.gz'.format(fqp=fqp,id=id),shell=True)

'''
****PART 2*** Initial quantification
-went back to tracking quant.sf since bad fastqs were removed
'''
rule build_salmon_index:
    input:  ref_fasta
    output:'ref/salmonindex'
    run:
        salmonindexcommand=loadSalmon + 'salmon index -t {} --gencode -i {} --type quasi --perfectHash -k 31'.format(input[0],output[0])
        sp.run(salmonindexcommand, shell=True)



rule run_salmon:
    input: lambda wildcards: ['fastq_files/{}_1.fastq.gz'.format(wildcards.sampleID),'fastq_files/{}_2.fastq.gz'.format(wildcards.sampleID)] if sample_dict[wildcards.sampleID]['paired'] else 'fastq_files/{}.fastq.gz'.format(wildcards.sampleID),
        'ref/salmonindex'
    output: 'quant_files/{sampleID}/quant.sf'
    log: 'logs/{sampleID}.log'
    run:
        id=wildcards.sampleID
        #tissue=wildcards.tissue
        paired=sample_dict[id]['paired']
        if paired:
            salmon_command=loadSalmon + 'salmon quant -i {} -l A --gcBias --seqBias -p 4  -1 {} -2 {} -o {}'.format(input[2],input[0],input[1],'quant_files/{}'.format(id))
        else:
            salmon_command=loadSalmon + 'salmon quant -i {} -l A --gcBias --seqBias -p 4 -r {} -o {}'.format(input[1],input[0],'quant_files/{}'.format(id))
        sp.run(salmon_command,shell=True)
        log1='logs/{}.log'.format(id)
        salmon_info='quant_files/{}/aux_info/meta_info.json'.format(id)
        if os.path.exists(salmon_info):
            with open(salmon_info) as file:
                salmonLog=json.load(file)
                mappingscore=salmonLog["percent_mapped"]
            if mappingscore <= 50:
                with open(log1,'w+') as logFile:
                    logFile.write('Sample {} failed QC mapping Percentage: {}'.format(id,mappingscore))
        else:
            with open(log1,'w+') as logFile:
                logFile.write('Sample {} failed to align'.format(id))

'''
****PART 3**** find and remove lowly used transcripts
'''
#problem with tximport; going to have to make a custom tsxdb from all the gtfs

rule find_tx_low_usage:
    input: expand('quant_files/{sampleID}/quant.sf', sampleID=sample_names), 'ref/gencodeAno_bsc.gtf'
    output:'tx_for_removal'
    shell:
        '''
        module load R
        Rscript scripts/soneson_low_usage.R {ref_GTF_basic}
        '''

rule remove_tx_low_usage:
    input:'tx_for_removal',ref_fasta
    output: 'ref/gencodeRef_trimmed.fa'
    run:
        with open(input[1]) as infasta, open('tx_for_removal') as bad_tx, open(output[0],'w+') as outfasta:
            names=set()
            for line in bad_tx:
                names.add('>'+line.strip())
            oldline=infasta.readline().strip().split('|')[0]
            while oldline:
                if oldline not in names and '>' in oldline:
                    write=True
                elif oldline in names and '>' in oldline:
                    write=False
                if write:
                    outfasta.write(oldline+'\n')
                oldline=infasta.readline().strip().strip().split('|')[0]


'''
***PART 4*** requantify salmon
-can't reverse index in shell apparently
'''

rule rebuild_salmon_index:
    input:'ref/gencodeRef_trimmed.fa'
    output:'ref/salmonindexTrimmed'
    run:
        salmonindexcommand=loadSalmon + 'salmon index -t {} code -i {} --type quasi --perfectHash -k 31'.format(input[0],output[0])
        sp.run(salmonindexcommand, shell=True)

rule reQuantify_Salmon:
    input: lambda wildcards: ['fastq_files/{}_1.fastq.gz'.format(wildcards.sampleID),'fastq_files/{}_2.fastq.gz'.format(wildcards.sampleID)] if sample_dict[wildcards.sampleID]['paired'] else 'fastq_files/{}.fastq.gz'.format(wildcards.sampleID),
            'ref/salmonindexTrimmed'
    output:'RE_quant_files/{sampleID}/quant.sf'
    log: 'logs/{sampleID}.rq.log'
    run:
        id=wildcards.sampleID
        #tissue=wildcards.tissue
        paired=sample_dict[id]['paired']
        if paired:
            salmon_command=loadSalmon + 'salmon quant -i {} -l A --gcBias --seqBias -p 8 -1 {} -2 {} -o {}'.format(input[2],input[0],input[1],'RE_quant_files/{}'.format(id))
        else:
            salmon_command=loadSalmon + 'salmon quant -i {} -l A --gcBias --seqBias -p 8 -r {} -o {}'.format(input[1],input[0],'RE_quant_files/{}'.format(id))
        sp.run(salmon_command,shell=True)
        log1='logs/{}.rq.log'.format(id)
        salmon_info='RE_quant_files/{}/aux_info/meta_info.json'.format( id)
        if os.path.exists(salmon_info):
            with open(salmon_info) as file:
                salmonLog=json.load(file)
                mappingscore=salmonLog["percent_mapped"]
            if mappingscore <= 50:
                with open(log1,'w+') as logFile:
                    logFile.write('Sample {} failed QC mapping Percentage: {}'.format(id,mappingscore))
        else:
            with open(log1,'w+') as logFile:
                logFile.write('Sample {} failed to align'.format(id))

rule quality_control:
    input:expand('RE_quant_files/{sampleID}/quant.sf',sampleID=sample_names),'ref/gencodeAno_bsc.gtf'
    output:'results/smoothed_filtered_tpms.csv'
    shell:
        '''
        module load R
        Rscript scripts/QC.R {config[sampleFile]} {ref_GTF_basic}

        '''
rule differntial_expression:
    input: 'results/smoothed_filtered_tpms.csv'
    output:'results/diffexp_efit.Rdata'
    shell:
        '''
        module load R
        Rscript scripts/diffExp.R
        '''
