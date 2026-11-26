SET SERVEROUTPUT ON;

CREATE TABLE AUDITORIA_EMPLOYEES (
    id_auditoria    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id     NUMBER(6) NOT NULL,
    campo           VARCHAR2(30) NOT NULL,
    valor_anterior  VARCHAR2(100),
    valor_nuevo     VARCHAR2(100),
    usuario         VARCHAR2(30) DEFAULT USER,
    fecha           DATE DEFAULT SYSDATE
);

CREATE OR REPLACE FUNCTION FN_ANIOS_SERVICIO (
    p_employee_id IN EMPLOYEES.employee_id%TYPE
) RETURN NUMBER
IS
    vd_ingreso EMPLOYEES.hire_date%TYPE;
BEGIN
    SELECT hire_date
      INTO vd_ingreso
      FROM EMPLOYEES
     WHERE employee_id = p_employee_id;

    RETURN TRUNC(MONTHS_BETWEEN(SYSDATE, vd_ingreso) / 12);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'No existe el empleado ' || p_employee_id);
END FN_ANIOS_SERVICIO;
/

CREATE OR REPLACE FUNCTION FN_SALARIO_EN_RANGO (
    p_employee_id IN EMPLOYEES.employee_id%TYPE
) RETURN VARCHAR2
IS
    vn_salario  EMPLOYEES.salary%TYPE;
    vn_minimo   JOBS.min_salary%TYPE;
    vn_maximo   JOBS.max_salary%TYPE;
BEGIN
    SELECT e.salary, j.min_salary, j.max_salary
      INTO vn_salario, vn_minimo, vn_maximo
      FROM EMPLOYEES e
      JOIN JOBS j ON j.job_id = e.job_id
     WHERE e.employee_id = p_employee_id;

    IF vn_salario < vn_minimo THEN
        RETURN 'POR DEBAJO DEL CARGO';
    ELSIF vn_salario > vn_maximo THEN
        RETURN 'POR ENCIMA DEL CARGO';
    ELSE
        RETURN 'EN RANGO';
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 'SIN DATOS';
END FN_SALARIO_EN_RANGO;
/

SELECT e.employee_id,
       e.first_name || ' ' || e.last_name  AS empleado,
       j.job_title,
       FN_ANIOS_SERVICIO(e.employee_id)    AS anios,
       FN_SALARIO_EN_RANGO(e.employee_id)  AS rango
  FROM EMPLOYEES e
  JOIN JOBS j ON j.job_id = e.job_id
 WHERE e.department_id = 50
 ORDER BY anios DESC;

DECLARE
    CURSOR cur_comision (p_department_id NUMBER, p_anios NUMBER) IS
        SELECT employee_id, first_name, last_name, commission_pct
          FROM EMPLOYEES
         WHERE department_id = p_department_id
           AND FN_ANIOS_SERVICIO(employee_id) >= p_anios
           FOR UPDATE OF commission_pct;

    vn_nueva  EMPLOYEES.commission_pct%TYPE;
    vn_total  PLS_INTEGER := 0;
BEGIN
    FOR vr IN cur_comision(80, 18) LOOP
        vn_nueva := LEAST(NVL(vr.commission_pct, 0) + 0.05, 0.40);

        UPDATE EMPLOYEES
           SET commission_pct = vn_nueva
         WHERE CURRENT OF cur_comision;

        vn_total := vn_total + 1;
        DBMS_OUTPUT.PUT_LINE(vr.first_name || ' ' || vr.last_name ||
                             ': ' || NVL(vr.commission_pct, 0) || ' -> ' || vn_nueva);
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('Empleados actualizados: ' || vn_total);
    ROLLBACK;
END;
/

CREATE OR REPLACE PROCEDURE SP_TRASLADAR_EMPLEADO (
    p_employee_id    IN EMPLOYEES.employee_id%TYPE,
    p_department_id  IN EMPLOYEES.department_id%TYPE
)
IS
    e_mismo_departamento EXCEPTION;
    vn_actual  EMPLOYEES.department_id%TYPE;
    vn_existe  PLS_INTEGER;
BEGIN
    SELECT COUNT(*)
      INTO vn_existe
      FROM DEPARTMENTS
     WHERE department_id = p_department_id;

    IF vn_existe = 0 THEN
        RAISE_APPLICATION_ERROR(-20002, 'No existe el departamento ' || p_department_id);
    END IF;

    SELECT department_id
      INTO vn_actual
      FROM EMPLOYEES
     WHERE employee_id = p_employee_id
       FOR UPDATE;

    IF vn_actual = p_department_id THEN
        RAISE e_mismo_departamento;
    END IF;

    UPDATE EMPLOYEES
       SET department_id = p_department_id
     WHERE employee_id = p_employee_id;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Empleado ' || p_employee_id || ' trasladado de ' ||
                         vn_actual || ' a ' || p_department_id);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20001, 'No existe el empleado ' || p_employee_id);
    WHEN e_mismo_departamento THEN
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20003, 'El empleado ya pertenece al departamento ' || p_department_id);
END SP_TRASLADAR_EMPLEADO;
/

CREATE OR REPLACE TRIGGER TGR_AU_EMPLOYEES_CAMBIOS
AFTER UPDATE OF salary, commission_pct, department_id ON EMPLOYEES
FOR EACH ROW
BEGIN
    IF NVL(:OLD.salary, -1) <> NVL(:NEW.salary, -1) THEN
        INSERT INTO AUDITORIA_EMPLOYEES (employee_id, campo, valor_anterior, valor_nuevo)
        VALUES (:NEW.employee_id, 'SALARY', TO_CHAR(:OLD.salary), TO_CHAR(:NEW.salary));
    END IF;

    IF NVL(:OLD.commission_pct, -1) <> NVL(:NEW.commission_pct, -1) THEN
        INSERT INTO AUDITORIA_EMPLOYEES (employee_id, campo, valor_anterior, valor_nuevo)
        VALUES (:NEW.employee_id, 'COMMISSION_PCT', TO_CHAR(:OLD.commission_pct), TO_CHAR(:NEW.commission_pct));
    END IF;

    IF NVL(:OLD.department_id, -1) <> NVL(:NEW.department_id, -1) THEN
        INSERT INTO AUDITORIA_EMPLOYEES (employee_id, campo, valor_anterior, valor_nuevo)
        VALUES (:NEW.employee_id, 'DEPARTMENT_ID', TO_CHAR(:OLD.department_id), TO_CHAR(:NEW.department_id));
    END IF;
END TGR_AU_EMPLOYEES_CAMBIOS;
/

CREATE OR REPLACE PACKAGE PKG_RRHH IS
    FUNCTION FN_COSTO_DEPARTAMENTO (p_department_id IN NUMBER) RETURN NUMBER;
    PROCEDURE SP_TRASLADO (p_employee_id IN NUMBER, p_department_id IN NUMBER);
    PROCEDURE SP_BONIFICAR_ANTIGUEDAD (p_department_id IN NUMBER, p_anios IN NUMBER, p_pct IN NUMBER);
    PROCEDURE SP_REPORTE_DEPARTAMENTO (p_department_id IN NUMBER);
END PKG_RRHH;
/

CREATE OR REPLACE PACKAGE BODY PKG_RRHH IS

    FUNCTION FN_COSTO_DEPARTAMENTO (p_department_id IN NUMBER) RETURN NUMBER IS
        vn_costo NUMBER;
    BEGIN
        SELECT NVL(SUM(salary * (1 + NVL(commission_pct, 0))), 0)
          INTO vn_costo
          FROM EMPLOYEES
         WHERE department_id = p_department_id;
        RETURN vn_costo;
    END FN_COSTO_DEPARTAMENTO;

    PROCEDURE SP_TRASLADO (p_employee_id IN NUMBER, p_department_id IN NUMBER) IS
    BEGIN
        SP_TRASLADAR_EMPLEADO(p_employee_id, p_department_id);
    END SP_TRASLADO;

    PROCEDURE SP_BONIFICAR_ANTIGUEDAD (p_department_id IN NUMBER, p_anios IN NUMBER, p_pct IN NUMBER) IS
        CURSOR cur_antiguos IS
            SELECT e.employee_id, e.salary, j.max_salary
              FROM EMPLOYEES e
              JOIN JOBS j ON j.job_id = e.job_id
             WHERE e.department_id = p_department_id
               FOR UPDATE OF e.salary;

        vn_nuevo  EMPLOYEES.salary%TYPE;
        vn_total  PLS_INTEGER := 0;
    BEGIN
        IF p_pct <= 0 OR p_pct > 20 THEN
            RAISE_APPLICATION_ERROR(-20004, 'El porcentaje debe estar entre 0 y 20');
        END IF;

        FOR vr IN cur_antiguos LOOP
            IF FN_ANIOS_SERVICIO(vr.employee_id) >= p_anios THEN
                vn_nuevo := LEAST(ROUND(vr.salary * (1 + p_pct / 100), 2), vr.max_salary);
                IF vn_nuevo > vr.salary THEN
                    UPDATE EMPLOYEES
                       SET salary = vn_nuevo
                     WHERE CURRENT OF cur_antiguos;
                    vn_total := vn_total + 1;
                END IF;
            END IF;
        END LOOP;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Empleados bonificados: ' || vn_total);
    END SP_BONIFICAR_ANTIGUEDAD;

    PROCEDURE SP_REPORTE_DEPARTAMENTO (p_department_id IN NUMBER) IS
        vc_nombre DEPARTMENTS.department_name%TYPE;

        CURSOR cur_reporte IS
            SELECT employee_id, first_name || ' ' || last_name AS empleado, salary
              FROM EMPLOYEES
             WHERE department_id = p_department_id
             ORDER BY salary DESC;
    BEGIN
        SELECT department_name
          INTO vc_nombre
          FROM DEPARTMENTS
         WHERE department_id = p_department_id;

        DBMS_OUTPUT.PUT_LINE(vc_nombre || ' | Costo mensual: ' ||
                             FN_COSTO_DEPARTAMENTO(p_department_id));
        FOR vr IN cur_reporte LOOP
            DBMS_OUTPUT.PUT_LINE(RPAD(vr.empleado, 25) || LPAD(vr.salary, 10) ||
                                 ' | ' || FN_ANIOS_SERVICIO(vr.employee_id) || ' anios' ||
                                 ' | ' || FN_SALARIO_EN_RANGO(vr.employee_id));
        END LOOP;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            DBMS_OUTPUT.PUT_LINE('No existe el departamento ' || p_department_id);
    END SP_REPORTE_DEPARTAMENTO;

END PKG_RRHH;
/

BEGIN
    PKG_RRHH.SP_REPORTE_DEPARTAMENTO(60);
    PKG_RRHH.SP_BONIFICAR_ANTIGUEDAD(60, 15, 8);
    PKG_RRHH.SP_TRASLADO(104, 90);

    BEGIN
        PKG_RRHH.SP_TRASLADO(104, 90);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(SQLERRM);
    END;

    BEGIN
        PKG_RRHH.SP_TRASLADO(104, 9999);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(SQLERRM);
    END;

    PKG_RRHH.SP_REPORTE_DEPARTAMENTO(60);
END;
/

SELECT employee_id, campo, valor_anterior, valor_nuevo, usuario, fecha
  FROM AUDITORIA_EMPLOYEES
 ORDER BY id_auditoria;

SELECT employee_id, start_date, end_date, job_id, department_id
  FROM JOB_HISTORY
 WHERE employee_id = 104;
