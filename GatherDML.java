import java.io.File;
import java.io.FileFilter;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.text.DateFormat;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.regex.*;

import org.apache.commons.io.FileUtils;
import org.apache.commons.io.filefilter.WildcardFileFilter;

/****
 * 
 * 
 * @author h877719 John Berry.
	1.	Pass in a directory string to the java app, if no directory is passed it uses a local directory GatherDMLFiles.   
		a.	It then parses through all files in the passed or local directory and reads each file into a string/string array. 
	2.	Read through each file to parse out ALL dml statements, or any pl/sql blocks (begin/end;) 
	3.	Export all DML statements or pl/sql blocks to a single file.  
		a.	These statements ignore all other comments etc.. 
		b.	So the generated file is a single pretty formatted file with all pertinent dmls inside. 
			i.	Work through any potential syntax errors so the dmls are accumulated correctly.
	4.	Parse each individual DML object for the underlying tables that modify.  
		a.	Keep a list of all modified objects by the dml or pl/sql statements.
		b.	Put a header comment at the top of the generated file with all modified tables so we can easily make backups.

  
  
 *
 */

public class GatherDML {
	private static ArrayList<String> tableList;
	
	public static void main(String[] args) {
		String sourceFolderString="";
		System.out.println("Parse through all files in a passed folder or local folder GatherDML (if no diectory location passed) and extract all dml statements into a single file with a header list of all tables modified.  ");
		if (args.length > 0) {
			if(!(args[0] ==null)) {
				sourceFolderString= args[0].trim();
			}	 
		}
		if( sourceFolderString == null ||sourceFolderString.length()<=0 ){
			System.out.println("No DML Source folder passed to string using default location of local in GatherDMLFiles local folder. ");
			sourceFolderString="./GatherDMLFiles";
		}
		/*
		try{
			 File dir = new File(sourceFolderString);
			 //dir.list();
		}
		catch(Exception e){
			System.out.println("Single file location parameter passed to app failed directory validation. pSource="+sourceFolderString);
			System.exit(-1);
		}
		*/
		try{
			GatherDMLFromFolder(sourceFolderString);
		}
		catch(Exception e){
			System.out.println("ERROR Gathering DML"+sourceFolderString+e);
			e.printStackTrace();
			System.exit(-1);
		}
	}
	private static void GatherDMLFromFolder(String pSource){
		File[] fileList; 
		String[] fileContents;
		//String[] fileStrip; //fileContents with all comments stripped out.
		
		//String[][] dmlArray;  // strore the list of dmls along with the dmls cooresponding tables and source file name.
		DMLFileObject[] dmlFile;
		 
		try {
			 File dir = new File(pSource);
			 FileFilter fileFilter = new WildcardFileFilter("*.sql*");  //only read in files that have .sql as part of the file name.  Files can still end in .txt as long as .sql exits.
			 fileList= dir.listFiles(fileFilter);
			 System.out.println("Total DML Files: "+fileList.length);
			 fileContents = new String[fileList.length];
			// fileStrip = new String[dmlFiles.length];
			 dmlFile = new DMLFileObject[fileList.length];
			 
	        for(int i = 0; i < fileList.length; i++){
	            System.out.println(fileList[i].getName());
	            fileContents[i]= FileUtils.readFileToString(fileList[i], StandardCharsets.UTF_8);
	            dmlFile[i]= new DMLFileObject(fileList[i].getName(), fileContents[i]);
	            dmlFile[i].buildDMLArray();
	        }
	        buildTableList(dmlFile);
	        writeDMLToFile(dmlFile);
		}
		catch (Exception e){
			System.out.println("Error Parsing through all files::: "+e);
		}
	}
	private static void writeDMLToFile(DMLFileObject[] pDMLFiles){
		//TODO write the built array of dml file objects that contain an array of dmls to disk.  Looping through both accordingly. 
		File outDir = null;
		FileOutputStream allFiles = null;
		FileOutputStream noCoFiles = null;
		FileOutputStream dmlFiles = null;
		String allStr ;
		String noCoStr;
		String dmlStr ;
		
		try {
			if (!(new File("./" +"PRESTO_DML" ).exists())) {
				if (!(new File("./" +"PRESTO_DML").mkdir()))
					System.out.println("Could not make ./PRESTO_DML  output directory");
			}
			outDir = new File("./"+"PRESTO_DML");
			
		} catch (Exception ei) {
			System.out.println("Problem creating directory ./PRESTO_DML");
			System.out.println(ei);
			ei.printStackTrace();
		}
		allStr =outDir+"/"+ getDate()+"_ALL_FILES_GATHERED.sql";
		noCoStr =outDir+"/"+ getDate()+"_ALL_FILES_NOCOMMENTS.sql";
		dmlStr =outDir+"/"+ getDate()+"_PRESTO_DML.sql";
		
		try {
			allFiles = new FileOutputStream(allStr);
			noCoFiles= new FileOutputStream(noCoStr);
			dmlFiles= new FileOutputStream(dmlStr);
			
			allFiles.write(("/*****  "+System.getProperty("line.separator")).getBytes());
			noCoFiles.write(("/*****  "+System.getProperty("line.separator")).getBytes());
			dmlFiles.write(("SET DEFINE OFF; SET TIMING ON; "+System.getProperty("line.separator")).getBytes());
			dmlFiles.write(("/*****  "+System.getProperty("line.separator")).getBytes());
			dmlFiles.write(("select 'create table '||user||'.'||table_name|| replace(owner, 'KPATHS', '')||'_'||to_char(sysdate, 'YYMMDD')||' as (select * from '||owner||'.'||table_name||') ;' as create_backup_stmt from all_tables WHERE OWNER like '%KPATHS%' AND TABLE_NAME IN ( ").getBytes());
			dmlFiles.write(System.getProperty("line.separator").getBytes());
			for(int i =0; i<tableList.size();i++){
				allFiles.write((tableList.get(i)+System.getProperty("line.separator")).getBytes());
				noCoFiles.write((", '"+tableList.get(i)+"'"+System.getProperty("line.separator")).getBytes());
				dmlFiles.write((", '"+tableList.get(i)+"'"+System.getProperty("line.separator")).getBytes());
			}
			dmlFiles.write((")  "+System.getProperty("line.separator")).getBytes());
			
			allFiles.write((" *****/ "+System.getProperty("line.separator")).getBytes());
			noCoFiles.write((" *****/ "+System.getProperty("line.separator")).getBytes());
			dmlFiles.write((" *****/ "+System.getProperty("line.separator")).getBytes());
			
			for(int i=0; i<pDMLFiles.length; i++){
				allFiles.write((pDMLFiles[i].fileText+System.getProperty("line.separator")).getBytes());
				noCoFiles.write((pDMLFiles[i].fileTextNoCo+System.getProperty("line.separator")).getBytes());
			}
			allFiles.close();
			noCoFiles.close();
			String curDML=null;
			for(int i = 0; i<pDMLFiles.length; i++){
				dmlFiles.write(("/*****  "+pDMLFiles[i].fileName +"  *****/"+System.getProperty("line.separator")).getBytes());
				for(int j=0;j<pDMLFiles[i].dmlList.size(); j++ ){
					curDML = pDMLFiles[i].dmlList.get(j).DML;
					dmlFiles.write((curDML+System.getProperty("line.separator")).getBytes());
				}
				dmlFiles.write((System.getProperty("line.separator")).getBytes());
			}
		} catch (Exception ei) {
			System.out.println("Problem CREATING output files " );
			System.out.println(ei);
			ei.printStackTrace();
		}
	}
	public static String removeComments(String pStr){
	    return pStr.replaceAll("(?s:/\\*.*?\\*/)|--.*", "");
	}
	
	private static void buildTableList(DMLFileObject[] pDMLFiles ){
		try{
			String curTable=null;
			tableList= new ArrayList<String>();
			
			if(pDMLFiles !=null){
				for(int i = 0; i<pDMLFiles.length; i++){
					for(int j=0;j<pDMLFiles[i].dmlList.size(); j++ ){
						curTable=(pDMLFiles[i].dmlList.get(j)).getTableName();
						if(!tableList.contains(curTable)){
							tableList.add(curTable);
						}
					}
				}
			}
			else {
				System.out.println("Can not build Table List until a the DMLFileList.  This is the final step after all dml is gathered in all objects.");
			}
		}
		catch(Exception e){
			System.out.println("Error building table list  "+e);
			e.printStackTrace();
		}
	}
	
	//Create DMLFileObject to hold all contents of file in one object.  File, filename, file contents, dmls contained within file.
	static class DMLFileObject{		
		//File  file; //file object of the string
		String fileName;  // the file name itself.
		String fileText; //contents within the file.
		String fileTextNoCo;
		//String[] DML;  //String array of all dmls contained within file.
		 //DMLObject[] DMLArray;
		ArrayList<DMLObject> dmlList;
		ArrayList<String> tableList;  // buildTableList() function to take all tables from DML array and create unique table list array.
		
		String curDMLText =null;
		//pl/sql files should only strip pl/sql blocks. If one is found do not strip dml blocks.  
		 boolean plsqlFlag = false;
		 
		public DMLFileObject(String fileName, String fileText)  { 
			this.fileName = fileName; 
			this.fileText = fileText; 
			this.fileTextNoCo=removeComments(this.fileText);
		}

		/*
		private void setFileName(String pFileName){
			fileName = pFileName;
		}
		private void setfileText(String pFileText){
			fileText = pFileText;
		}

		*/
		// this class is meant to parse through the dml file contents and build the dmlObject[] array within this class.
		//TODO loop through the filetext of this object and build the array list of dmlobjects.  
		//utilize parseDMLInString at a start position to incrementally parse through the text to pull out all text.
		
		private void buildDMLArray (){//Assumes the fileText variable has already been set when the object is initialized.
			try{
				//need to find out total number of dmls in string before initializing the array. 
				//DMLArray = new DMLObject
				DMLObject curDML ; //used for the current dml object thats found.  Once built add to the dmlList.
				dmlList = new 	ArrayList<DMLObject>();
				
				String regexDML = "^((INSERT|UPDATE|DELETE|MERGE)(?:[^;']++|(?:'[^']++'))+;)?\\s*$";
				//try to exclude delcare/end; blocks from dml expression. 
				//String regexDML = "^((INSERT|UPDATE|DELETE|MERGE)(?:[^;']++|(DECLARE(.*?)END;)|(?:'[^']++'))+;)?\\s*$";
				
				regexDML= String.format("(%s)+", regexDML);
				
				//BEGIN((?!PROCEDURE).)*END;
				//String regexPLSQL = "^(BEGIN)(?:[^END;']+|(?:'[^']+'))+END;\\s*$";
				String regexPLSQL = "DECLARE(.*?)END;";
				
				Pattern dmlPattern = Pattern.compile(regexDML, Pattern.MULTILINE | Pattern.DOTALL| Pattern.CASE_INSENSITIVE );
				Pattern plsqlPattern = Pattern.compile(regexPLSQL, Pattern.MULTILINE | Pattern.DOTALL | Pattern.CASE_INSENSITIVE);
								
				Matcher dmlMatcher = dmlPattern.matcher(fileTextNoCo);
				Matcher plsqlMatcher = plsqlPattern.matcher(this.fileText);
		
				while (plsqlMatcher.find()) {
					//System.out.println(dmlMatcher.group(0));
					if(plsqlMatcher.group(0).trim().length()>1 ){
						curDML = new DMLObject();
						curDML.SourceName=this.fileName;
						curDML.DML=plsqlMatcher.group(0)+System.getProperty("line.separator")+"/"+System.getProperty("line.separator");
						curDML.setPLSQL(true);
						curDML.parseTableName();
						dmlList.add(curDML);  
						this.plsqlFlag=true;
					}
				}
				//list.get(list.size() - 1);
				while (dmlMatcher.find()) {
					//System.out.println(dmlMatcher.group(0));
					if(dmlMatcher.group(0).trim().length()>1   && !this.plsqlFlag 
					){
						curDML = new DMLObject();
						curDML.SourceName=this.fileName;
						curDML.DML=dmlMatcher.group(0);
						 curDML.parseTableName();
						dmlList.add(curDML);  
					}
				}
				
				
			}
			catch(Exception e){
				System.out.println("Error gathering DML with regular expression::: "+e);
				e.printStackTrace();
			}
			System.gc();
			
		}
	}
	//Create DML object that stores the dml statement, tables it modifies (single object or comma delimited list for pl/sql blocks.  and a boolean flag to say the DML object is dml or pl/sql. 
	static class DMLObject{
	    String DML=null; //This can be a single dml statement or a pl/sql block. Is there a way to enforce this from the object itself? 
	    String TableName=null; //The underlying table the DML statement modifies.  pl/sql dml objects may have more than one table in a comma separated list.  DML objects will only have a single object.
	    String SourceName=null; //File name or package name from which it was extracted.
	    boolean plsqlFlag = false;
	    
	    public DMLObject() {	
	    }
	    
	    private void setPLSQL(boolean pPlsqlFlag){
	    	this.plsqlFlag=pPlsqlFlag;
	    }

	    private String getTableName(){
	    	return TableName;
	    }
	    private void parseTableName(){// parse through the DML string passed for the tables which have been modified.  This builds and sets TableName.
	    	//special logic for pl/sql blocks to strip out dml from them and then parse out list of tablenames.
			//String regexDML = "^((INSERT|UPDATE|DELETE|MERGE|BEGIN)(?:[^;']++|(?:'[^']++'))+;)?\\s*$";
	    	String regexTable = "^(INSERT\\s*INTO|MERGE\\s*INTO|DELETE\\s*FROM|UPDATE)\\s+(?<table>(\\S|\\()+)";
	    	//    "(INSERT\S+INTO|UPDATE|DELETE|MERGE\S+INTO)\s+(?<table>\S+)
	    	
	    	Pattern tablePattern = Pattern.compile(regexTable, Pattern.MULTILINE | Pattern.DOTALL| Pattern.CASE_INSENSITIVE );
			Matcher tableMatcher = tablePattern.matcher(this.DML);
			if (tableMatcher.find()) {
				this.TableName = tableMatcher.group(0).replaceAll("(?i)^(INSERT\\s*INTO|MERGE\\s*INTO|DELETE\\s*FROM|UPDATE\\s*)", "").trim().toUpperCase();
				this.TableName= this.TableName.replace("\"", "");
				
				
				//if(this.TableName.length()>21){
					//System.out.println(this.TableName);
					this.TableName = this.TableName.replaceAll("[^a-zA-Z_].*$", "");
					this.TableName= this.TableName.replace("(", "");
					//System.out.println(this.TableName);
				//}
					
			}
	    }
	}
	private static String getDate() {
        DateFormat dateFormat = new SimpleDateFormat("yyyyMMdd_HH_mm_ss");
        //DateFormat dateFormat = new SimpleDateFormat("dd-MMM-yyyy");
    	
        Date date = new Date();
        return dateFormat.format(date);
    }
}
